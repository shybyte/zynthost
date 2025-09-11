const std = @import("std");

const c = @cImport({
    @cInclude("lilv-0/lilv/lilv.h");
    @cInclude("lv2/core/lv2.h");
    @cInclude("lv2/atom/atom.h");
    @cInclude("lv2/midi/midi.h");
    @cInclude("lv2/urid/urid.h");
});

const MidiSequence = @import("midi_sequence.zig").MidiSequence;

const sample_rate: f64 = 48000.0;
const nframes: u32 = 256;

pub const SynthPlugin = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    instance: [*c]c.LilvInstance,

    audio_in_bufs: []?[]f32,
    audio_out_bufs: []?[]f32,
    control_in_vals: []f32,

    pub fn init(
        allocator: std.mem.Allocator,
        world: *c.LilvWorld,
        plugin_uri_string: [*:0]const u8, // already a valid C string
    ) !*Self {
        // Allocate the plugin struct first
        const self = try allocator.create(SynthPlugin);
        errdefer allocator.destroy(self);
        self.allocator = allocator;

        // Ensure plugin list exists
        const plugins = c.lilv_world_get_all_plugins(world);
        if (plugins == null) return error.NoPlugins;

        const plugin_uri = c.lilv_new_uri(world, plugin_uri_string);
        if (plugin_uri == null) return error.BadPluginUri;
        defer c.lilv_node_free(plugin_uri);

        const plugin = c.lilv_plugins_get_by_uri(plugins, plugin_uri);
        if (plugin == null) return error.PluginNotFound;
        // (Optionally, keep a handle/reference to `plugin` here if needed later)

        // ----------------------------
        // 2) Provide LV2_URID_Map feature
        // ----------------------------
        try initUridTable(allocator); // initializes global URI→URID map used by the C callback

        var urid_map_feature_data: c.LV2_URID_Map = .{
            .handle = null,
            .map = urid_map_func,
        };

        var urid_map_feature: c.LV2_Feature = .{
            .URI = "http://lv2plug.in/ns/ext/urid#map",
            .data = &urid_map_feature_data,
        };

        var features = [_]?*const c.LV2_Feature{
            &urid_map_feature,
            null, // terminator
        };

        // ----------------------------
        // 3) Instantiate the plugin
        // ----------------------------
        self.instance = c.lilv_plugin_instantiate(plugin, sample_rate, &features);
        if (self.instance == null) return error.InstanceFailed;

        try connectPorts(self, world, plugin);

        return self;
    }

    fn connectPorts(self: *Self, world: *c.LilvWorld, plugin: ?*const c.LilvPlugin) !void {
        // ----------------------------
        // 4) Discover ports & connect minimal buffers
        //    - find MIDI input Atom port
        //    - connect audio outs (and ins if present) to temporary buffers
        //    - connect control inputs to 0.0 or default
        // ----------------------------
        // URIs we’ll match against
        const uri_lv2_InputPort = c.lilv_new_uri(world, "http://lv2plug.in/ns/lv2core#InputPort");
        const uri_lv2_OutputPort = c.lilv_new_uri(world, "http://lv2plug.in/ns/lv2core#OutputPort");
        const uri_lv2_AudioPort = c.lilv_new_uri(world, "http://lv2plug.in/ns/lv2core#AudioPort");
        const uri_lv2_ControlPort = c.lilv_new_uri(world, "http://lv2plug.in/ns/lv2core#ControlPort");
        const uri_atom_AtomPort = c.lilv_new_uri(world, "http://lv2plug.in/ns/ext/atom#AtomPort");
        const uri_midi_MidiEvent = c.lilv_new_uri(world, "http://lv2plug.in/ns/ext/midi#MidiEvent");

        defer {
            c.lilv_node_free(uri_lv2_InputPort);
            c.lilv_node_free(uri_lv2_OutputPort);
            c.lilv_node_free(uri_lv2_AudioPort);
            c.lilv_node_free(uri_lv2_ControlPort);
            c.lilv_node_free(uri_atom_AtomPort);
            c.lilv_node_free(uri_midi_MidiEvent);
        }

        const nports: u32 = @intCast(c.lilv_plugin_get_num_ports(plugin));

        // temp storage for audio/control ports
        const allocator = self.allocator;
        self.audio_in_bufs = try allocator.alloc(?[]f32, nports);
        // const audio_in_bufs: []?[]f32 = try allocator.alloc(?[]f32, nports);
        @memset(self.audio_in_bufs, null);
        // defer allocator.free(self.audio_in_bufs);
        self.audio_out_bufs = try allocator.alloc(?[]f32, nports);
        @memset(self.audio_out_bufs, null);
        // defer allocator.free(audio_out_bufs);
        self.control_in_vals = try allocator.alloc(f32, nports);
        // defer allocator.free(control_in_vals);

        // initialize to empty
        // for (audio_in_bufs) |*slot| slot.* = &[_]f32{};
        // for (audio_out_bufs) |*slot| slot.* = &[_]f32{};
        @memset(self.control_in_vals, 0);

        // pick a MIDI input port
        var midi_in_port_index: ?u32 = null;

        var p: u32 = 0;
        while (p < nports) : (p += 1) {
            const port = c.lilv_plugin_get_port_by_index(plugin, p);

            const is_input = c.lilv_port_is_a(plugin, port, uri_lv2_InputPort);
            const is_output = c.lilv_port_is_a(plugin, port, uri_lv2_OutputPort);
            const is_audio = c.lilv_port_is_a(plugin, port, uri_lv2_AudioPort);
            const is_control = c.lilv_port_is_a(plugin, port, uri_lv2_ControlPort);
            const is_atom = c.lilv_port_is_a(plugin, port, uri_atom_AtomPort);

            // find MIDI Atom input
            if (is_input and is_atom and midi_in_port_index == null) {
                // Does it support midi:MidiEvent?
                if (c.lilv_port_supports_event(plugin, port, uri_midi_MidiEvent)) {
                    midi_in_port_index = p;
                    // (we'll connect the actual sequence buffer later)
                    continue;
                }
            }

            if (is_audio) {
                // allocate audio buffers
                const buf = try allocator.alloc(f32, nframes);
                @memset(buf, 0);
                if (is_input) {
                    self.audio_in_bufs[p] = buf;
                    c.lilv_instance_connect_port(self.instance, p, buf.ptr);
                } else if (is_output) {
                    std.debug.print("Found Audio out at port {} \n", .{p});
                    self.audio_out_bufs[p] = buf;
                    c.lilv_instance_connect_port(self.instance, p, buf.ptr);
                }
            } else if (is_control and is_input) {
                // set control input to default if available, else 0.0
                var def_node: ?*c.LilvNode = null;
                var min_node: ?*c.LilvNode = null;
                var max_node: ?*c.LilvNode = null;

                // Make C-pointer views for the out-params (types: [*c]?*const c.LilvNode)
                const def_ptr: [*c]?*c.LilvNode = &def_node;
                const min_ptr: [*c]?*c.LilvNode = &min_node;
                const max_ptr: [*c]?*c.LilvNode = &max_node;

                // c.lilv_port_get_range(plugin, port, &def_node, &min_node, &max_node);
                c.lilv_port_get_range(plugin, port, def_ptr, min_ptr, max_ptr);
                const v: f32 = if (def_node) |dn| @floatCast(c.lilv_node_as_float(dn)) else 0.0;
                self.control_in_vals[p] = v;
                // std.debug.print("Set Controll {}\n", .{self.control_in_vals[p]});
                c.lilv_instance_connect_port(self.instance, p, &self.control_in_vals[p]);
            } else {
                // For non-audio/atom outputs etc., we skip in this minimal example.
                // Many synths will still run fine.
            }
        }

        if (midi_in_port_index == null) {
            return error.NoMidiInputFound;
        }

        // ----------------------------
        // 5) Activate, send ONE MIDI Note On, run one cycle
        // ----------------------------
        c.lilv_instance_activate(self.instance);

        // Minimal URID mapping for types we need
        const atom_Sequence_urid = urid_map_func(null, "http://lv2plug.in/ns/ext/atom#Sequence");
        const midi_MidiEvent_urid = urid_map_func(null, "http://lv2plug.in/ns/ext/midi#MidiEvent");
        const midi_timeframe_urid = urid_map_func(null, "http://lv2plug.in/ns/ext/time#frame");

        var backing: [1024]u8 align(8) = undefined;
        var ms = MidiSequence.init(backing[0..], atom_Sequence_urid, midi_MidiEvent_urid, midi_timeframe_urid);
        try ms.addEvent(0, &[_]u8{ 0x90, 60, 127 });

        // Connect the MIDI sequence to the discovered MIDI input port
        c.lilv_instance_connect_port(self.instance, midi_in_port_index.?, ms.seq());
    }

    pub fn run(self: *Self) void {
        c.lilv_instance_run(self.instance, nframes);
    }

    pub fn deinit(self: *Self) void {
        for (self.audio_in_bufs) |audio_buf_opt| {
            if (audio_buf_opt) |audio_buf| {
                self.allocator.free(audio_buf);
            }
        }
        self.allocator.free(self.audio_in_bufs);

        for (self.audio_out_bufs) |audio_buf_opt| {
            if (audio_buf_opt) |audio_buf| {
                self.allocator.free(audio_buf);
            }
        }
        self.allocator.free(self.audio_out_bufs);

        self.allocator.free(self.control_in_vals);

        c.lilv_instance_deactivate(self.instance);
        c.lilv_instance_free(self.instance);
        self.allocator.destroy(self);
    }
};

// ===========================================================
// Simple global URI→URID map for LV2_URID_Map (host feature)
// ===========================================================
var next_urid: c_uint = 1;
var uri_table: std.StringHashMap(c_uint) = undefined;
var table_inited = false;

fn initUridTable(allocator: std.mem.Allocator) !void {
    if (!table_inited) {
        uri_table = std.StringHashMap(c_uint).init(allocator);
        table_inited = true;
    }
}

fn deinitUridTable() void {
    uri_table.deinit();
}

export fn urid_map_func(handle: ?*anyopaque, uri: ?[*:0]const u8) callconv(.c) c.LV2_URID {
    _ = handle;
    const s = std.mem.span(uri.?);

    if (table_inited) {
        if (uri_table.get(s)) |found| return found;
        // Copy the key because s points to plugin/lilv-owned memory
        const dup = std.heap.page_allocator.dupe(u8, s) catch return 0;
        const id: c_uint = next_urid;
        next_urid += 1;
        _ = uri_table.put(dup, id) catch return 0;
        return id;
    } else {
        // Fallback linear counter if somehow called before init
        const id2: c_uint = next_urid;
        next_urid += 1;
        return id2;
    }
}

// ---- Tests ----

test "SynthPlugin initialization and deinitialization" {
    // Use the built-in testing allocator
    const allocator = std.testing.allocator;

    const world = c.lilv_world_new();
    try std.testing.expect(world != null);
    defer c.lilv_world_free(world.?);

    c.lilv_world_load_all(world.?);

    // Initialize with a known valid C string literal
    var synth_plugin = try SynthPlugin.init(allocator, world.?, "https://surge-synthesizer.github.io/lv2/surge-xt");
    defer synth_plugin.deinit();
    defer deinitUridTable();

    synth_plugin.run();

    std.debug.print(" {any}\n", .{synth_plugin.audio_out_bufs[5]});

    // Ensure initialization returned a non-null pointer
    // try std.testing.expect(synth_plugin != null);

    // (deinit will run via defer; no double free)

}
