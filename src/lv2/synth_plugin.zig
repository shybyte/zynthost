const std = @import("std");
const host = @import("host.zig");

const c = host.c;

const MidiSequence = @import("midi_sequence.zig").MidiSequence;
const UiSession = @import("ui_session.zig").UiSession;

const sample_rate: f64 = 48000.0;
pub const max_frames: u32 = 4096;

pub const SynthPlugin = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    world: *c.LilvWorld,

    plugin_uri_string: []const u8,
    plugin_uri: *c.LilvNode,
    plugin: *const c.LilvPlugin,
    instance: [*c]c.LilvInstance,

    audio_in_bufs: []?[]f32,
    audio_out_bufs: []?[]f32,
    audio_ports: std.ArrayList(usize),

    control_in_vals: []f32,
    backing: [1024]u8 align(8),
    midi_sequence: MidiSequence,

    session: ?UiSession,

    pub fn init(
        allocator: std.mem.Allocator,
        world: *c.LilvWorld,
        plugin_uri_string: [:0]const u8, // already a valid C string
    ) !*Self {
        const self = try allocator.create(SynthPlugin);
        errdefer allocator.destroy(self);

        self.session = null;
        self.allocator = allocator;
        self.world = world;

        const plugins = c.lilv_world_get_all_plugins(world);
        if (plugins == null) return error.NoPlugins;

        self.plugin_uri_string = try allocator.dupe(u8, plugin_uri_string);
        errdefer allocator.free(self.plugin_uri_string);
        self.plugin_uri = c.lilv_new_uri(world, plugin_uri_string) orelse return error.BadPluginUri;
        errdefer c.lilv_node_free(self.plugin_uri);
        self.plugin = c.lilv_plugins_get_by_uri(plugins, self.plugin_uri) orelse return error.PluginNotFound;

        const lv2_host = host.get();
        self.instance = c.lilv_plugin_instantiate(self.plugin, sample_rate, lv2_host.featurePtr());
        if (self.instance == null) return error.InstanceFailed;

        try connectPorts(self, world, self.plugin);

        return self;
    }

    fn connectPorts(self: *Self, world: *c.LilvWorld, plugin: ?*const c.LilvPlugin) !void {
        const lv2_host = host.get();
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
        self.audio_ports = try std.ArrayList(usize).initCapacity(self.allocator, nports);
        errdefer self.audio_ports.deinit(self.allocator);

        // temp storage for audio/control ports
        const allocator = self.allocator;

        self.audio_in_bufs = try allocator.alloc(?[]f32, nports);
        // const audio_in_bufs: []?[]f32 = try allocator.alloc(?[]f32, nports);
        @memset(self.audio_in_bufs, null);
        errdefer {
            for (self.audio_in_bufs) |audio_buf_opt| {
                if (audio_buf_opt) |audio_buf| {
                    self.allocator.free(audio_buf);
                }
            }
            allocator.free(self.audio_in_bufs);
        }

        self.audio_out_bufs = try allocator.alloc(?[]f32, nports);
        @memset(self.audio_out_bufs, null);
        errdefer {
            for (self.audio_out_bufs) |audio_buf_opt| {
                if (audio_buf_opt) |audio_buf| {
                    self.allocator.free(audio_buf);
                }
            }
            allocator.free(self.audio_out_bufs);
        }

        self.control_in_vals = try allocator.alloc(f32, nports);
        errdefer allocator.free(self.control_in_vals);
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
                const buf = try allocator.alloc(f32, max_frames);
                @memset(buf, 0);
                if (is_input) {
                    self.audio_in_bufs[p] = buf;
                    c.lilv_instance_connect_port(self.instance, p, buf.ptr);
                } else if (is_output) {
                    std.debug.print("Found Audio out at port {} \n", .{p});
                    self.audio_ports.appendAssumeCapacity(p);
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

                // const sym_node = c.lilv_port_get_symbol(self.plugin, port);
                // const sym_c = c.lilv_node_as_string(sym_node) orelse continue;
                // std.debug.print("Set Controll {} {s} {}\n", .{ p, sym_c, self.control_in_vals[p] });

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
        const atom_Sequence_urid = lv2_host.mapUri("http://lv2plug.in/ns/ext/atom#Sequence");
        const midi_MidiEvent_urid = lv2_host.mapUri("http://lv2plug.in/ns/ext/midi#MidiEvent");
        const midi_timeframe_urid = lv2_host.mapUri("http://lv2plug.in/ns/ext/time#frame");

        self.midi_sequence = MidiSequence.init(self.backing[0..], atom_Sequence_urid, midi_MidiEvent_urid, midi_timeframe_urid);
        // try self.midi_sequence.addEvent(0, &[_]u8{ 0x90, 60, 127 });

        // Connect the MIDI sequence to the discovered MIDI input port
        c.lilv_instance_connect_port(self.instance, midi_in_port_index.?, self.midi_sequence.seq());
    }

    pub fn showUI(self: *Self) !void {
        self.session = UiSession{};
        errdefer self.session = null;
        try self.session.?.init(.{
            .allocator = self.allocator,
            .world = self.world,
            .plugin_uri_string = self.plugin_uri_string,
            .plugin_uri = self.plugin_uri,
            .plugin = self.plugin,
            .instance = self.instance,
            .control_in_vals = self.control_in_vals,
        });
    }

    pub fn run(self: *Self, frames: u32) void {
        // _ = self;
        c.lilv_instance_run(self.instance, frames);
        self.midi_sequence.clear();
        // std.debug.print("Test {any}\n", .{self.instance});
    }

    pub fn saveState(self: *Self, file_path: [:0]const u8) !void {
        const lv2_host = host.get();
        const dir = try self.allocator.dupeZ(u8, std.fs.path.dirname(file_path) orelse "");
        defer self.allocator.free(dir);

        std.debug.print("saveState {s} {s}\n", .{ dir, file_path });

        const state = c.lilv_state_new_from_instance(
            self.plugin,
            self.instance,
            lv2_host.uridMap(),
            dir,
            dir,
            dir,
            dir,
            null,
            null,
            0,
            null, // const LV2_Feature* const* (optional)
        );

        if (state == null) {
            std.debug.print("lilv_state_new_from_instance returned null (plugin may require extra state features).\n", .{});
            return error.StateCreationFailed;
        }
        defer c.lilv_state_free(state.?);

        std.debug.print("Successfully created LV2 state from instance.\n", .{});

        // Save: Lilv will create a .ttl, and possibly a directory for blobs
        const ok = c.lilv_state_save(
            self.world,
            lv2_host.uridMap(),
            lv2_host.uridUnmap(),
            state,
            null, // uri for the state (optional, host-specific)
            dir,
            @ptrCast(std.fs.path.basename(file_path)),
        );
        if (ok != 0) {
            return error.SaveFailed;
        }

        std.debug.print("Successfully saved LV2 state from instance.\n", .{});
    }

    pub fn loadState(self: *Self, file_path: [:0]const u8) !void {
        const lv2_host = host.get();
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.debug.print("Can't open file '{s}'.\n", .{file_path});
            return err;
        };
        defer file.close();

        const state = c.lilv_state_new_from_file(
            self.world,
            lv2_host.uridMap(),
            null,
            file_path,
        );

        if (state == null) {
            std.debug.print("Failed to load LV2 state from {s}\n", .{file_path});
            return error.StateLoadFailed;
        }

        defer c.lilv_state_free(state.?);

        // Many plugins expect to be inactive while restoring
        c.lilv_instance_deactivate(self.instance);

        c.lilv_state_restore(
            state.?,
            self.instance,
            setPortValueBySymbol, // will write control values into control_in_vals
            self, // user_data passed to setPortValue
            0, // flags (usually 0)
            null, // const LV2_Feature* const* (optional extra features)
        );

        // Reactivate either way; bail on error
        c.lilv_instance_activate(self.instance);

        std.debug.print("Successfully restored LV2 state from {s}\n", .{file_path});
    }

    pub fn deinit(self: *Self) void {
        std.debug.print("deinit {s} ... \n", .{self.plugin_uri_string});

        if (self.session) |*running_session| {
            running_session.deinit();
            self.session = null;
        }

        c.lilv_instance_deactivate(self.instance);
        c.lilv_instance_free(self.instance);
        c.lilv_node_free(self.plugin_uri);
        std.debug.print("lilv denit is done for {s} ... \n", .{self.plugin_uri_string});

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
        self.audio_ports.deinit(self.allocator);

        self.allocator.free(self.control_in_vals);

        std.debug.print("deinit {s} done \n", .{self.plugin_uri_string});
        self.allocator.free(self.plugin_uri_string);
        self.allocator.destroy(self);
        std.debug.print("really done \n", .{});
    }
};

// Find a port index by its symbol (C string) on this plugin
fn findPortIndexBySymbol(self: *SynthPlugin, sym_c: [*c]const u8) ?u32 {
    const sym = std.mem.span(sym_c);
    const nports: u32 = @intCast(c.lilv_plugin_get_num_ports(self.plugin));
    var p: u32 = 0;
    while (p < nports) : (p += 1) {
        const port = c.lilv_plugin_get_port_by_index(self.plugin, p);
        const node = c.lilv_port_get_symbol(self.plugin, port);
        if (node != null) {
            const node_c: [*:0]const u8 = c.lilv_node_as_string(node);
            if (std.mem.eql(u8, std.mem.span(node_c), sym)) return p;
        }
    }
    return null;
}

// Correct LilvSetPortValueFunc signature (symbol-based)
fn setPortValueBySymbol(
    port_symbol: [*c]const u8,
    user_data: ?*anyopaque,
    value: ?*const anyopaque,
    size: u32,
    type_urid: u32,
) callconv(.c) void {
    _ = type_urid; // Most control floats use 0; we don't need to branch on type here.
    if (user_data == null or value == null) return;

    const self: *SynthPlugin = @ptrCast(@alignCast(user_data.?));

    std.debug.print("setPortValueBySymbol {s}\n", .{port_symbol});

    // We only handle simple control floats wired to control_in_vals
    if (size != @sizeOf(f32)) return;

    const idx = findPortIndexBySymbol(self, port_symbol) orelse return;

    // Bounds-checked write into the backing buffer already connected to the plugin
    if (idx < self.control_in_vals.len) {
        const fptr: *const f32 = @ptrCast(@alignCast(value.?));
        self.control_in_vals[idx] = fptr.*;
    }
}

var zero: f32 = 0;

fn get_value(port_symbol: [*c]const u8, user_data: ?*anyopaque, size: [*c]u32, value_type: [*c]u32) callconv(.c) ?*const anyopaque {
    _ = user_data;
    // _ = port_symbol;
    // _ = size;
    // _ = value_type;
    std.debug.print("get_value {s}\n", .{port_symbol});
    const float_id = host.get().mapUri("http://lv2plug.in/ns/ext/atom#Float");
    // _ = port_symbol;
    value_type.* = float_id;
    size.* = @sizeOf(f32);
    return &zero;
    // value_type.* = 0;
    // size.* = 0;
    // return null;
}

// ---- Tests ----

test "SynthPlugin" {
    const allocator = std.testing.allocator;

    const lv2_host = try host.initGlobal(allocator);
    defer host.deinitGlobal();

    const world = lv2_host.worldPtr();

    // listPlugins(world.?);

    // Initialize with a known valid C string literal
    var synth_plugin = try SynthPlugin.init(allocator, world, "https://surge-synthesizer.github.io/lv2/surge-xt");
    defer synth_plugin.deinit();

    try synth_plugin.saveState("patches/tmp/patch.ttl");
    try synth_plugin.loadState("patches/tmp/patch.ttl");

    try std.testing.expectEqual(2, synth_plugin.audio_ports.items.len);
    try std.testing.expectEqual(5, synth_plugin.audio_ports.items[0]);
    try std.testing.expectEqual(6, synth_plugin.audio_ports.items[1]);

    try synth_plugin.midi_sequence.addEvent(0, &[_]u8{ 0x90, 60, 127 });
    synth_plugin.run(256);

    std.debug.print(" {any}\n", .{synth_plugin.audio_out_bufs[5].?[0..100]});

    const file_name = "patches/tmp/test-plugin-patch.json";
    try synth_plugin.saveState(file_name);
    try synth_plugin.loadState(file_name);
}
