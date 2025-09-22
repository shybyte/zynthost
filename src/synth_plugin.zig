const std = @import("std");

const c = @cImport({
    @cInclude("lilv-0/lilv/lilv.h");
    @cInclude("lv2/core/lv2.h");
    @cInclude("lv2/atom/atom.h");
    @cInclude("lv2/midi/midi.h");
    @cInclude("lv2/urid/urid.h");
    @cInclude("lv2/ui/ui.h");
    @cInclude("suil-0/suil/suil.h");
    @cInclude("dlfcn.h");
});

const MidiSequence = @import("midi_sequence.zig").MidiSequence;
const utils = @import("utils.zig");

const sample_rate: f64 = 48000.0;
pub const max_frames: u32 = 4096;

pub const SynthPlugin = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    world: *c.LilvWorld,

    plugin_uri: *c.LilvNode,
    plugin: *const c.LilvPlugin,
    instance: [*c]c.LilvInstance,

    audio_in_bufs: []?[]f32,
    audio_out_bufs: []?[]f32,
    control_in_vals: []f32,
    backing: [1024]u8 align(8),
    midi_sequence: MidiSequence,

    pub fn init(
        allocator: std.mem.Allocator,
        world: *c.LilvWorld,
        plugin_uri_string: [*:0]const u8, // already a valid C string
    ) !*Self {

        // Allocate the plugin struct first
        const self = try allocator.create(SynthPlugin);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.world = world;

        // Ensure plugin list exists
        const plugins = c.lilv_world_get_all_plugins(world);
        if (plugins == null) return error.NoPlugins;

        self.plugin_uri = c.lilv_new_uri(world, plugin_uri_string) orelse return error.BadPluginUri;
        defer c.lilv_node_free(self.plugin_uri);

        self.plugin = c.lilv_plugins_get_by_uri(plugins, self.plugin_uri) orelse return error.PluginNotFound;

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
        self.instance = c.lilv_plugin_instantiate(self.plugin, sample_rate, &features);
        if (self.instance == null) return error.InstanceFailed;

        try connectPorts(self, world, self.plugin);

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
                const buf = try allocator.alloc(f32, max_frames);
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

        self.midi_sequence = MidiSequence.init(self.backing[0..], atom_Sequence_urid, midi_MidiEvent_urid, midi_timeframe_urid);
        // try self.midi_sequence.addEvent(0, &[_]u8{ 0x90, 60, 127 });

        // Connect the MIDI sequence to the discovered MIDI input port
        c.lilv_instance_connect_port(self.instance, midi_in_port_index.?, self.midi_sequence.seq());
    }

    pub fn showUI(self: *Self) !void {
        const world = self.world;
        const plugin = self.plugin;

        const ext_ui_class = c.lilv_new_uri(world, "http://kxstudio.sf.net/ns/lv2ext/external-ui#Widget");
        defer c.lilv_node_free(ext_ui_class);

        try self.listUIs();

        // pick ExternalUI
        const uis = c.lilv_plugin_get_uis(plugin);
        var it = c.lilv_uis_begin(uis);
        var ui: ?*const c.LilvUI = null;
        while (!c.lilv_uis_is_end(uis, it)) : (it = c.lilv_uis_next(uis, it)) {
            const u = c.lilv_uis_get(uis, it);
            if (c.lilv_ui_is_a(u, ext_ui_class)) {
                ui = u;
                break;
            }
        }
        if (ui == null) return;

        // Required strings
        const plugin_uri_c = c.lilv_node_as_uri(self.plugin_uri); // plugin URI
        const ui_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_uri(ui.?)); // selected UI URI
        const ui_type_uri_c = "http://kxstudio.sf.net/ns/lv2ext/external-ui#Widget";

        // Convert bundle/bin URIs → filesystem paths
        const binary_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_binary_uri(ui.?)) orelse return;
        const binary_path_c = try utils.convertUritoPath(self.allocator, binary_uri_c);
        defer self.allocator.free(binary_path_c);
        std.debug.print("binary_path_c {s}\n", .{binary_path_c});

        const bundle_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_bundle_uri(ui.?)) orelse return;
        const bundle_path_c = try utils.convertUritoPath(self.allocator, bundle_uri_c);
        defer self.allocator.free(bundle_path_c);
        std.debug.print("bundle_path_c {s}\n", .{bundle_path_c});

        // suil host
        const host = c.suil_host_new(uiWrite, uiIndex, uiSubscribe, uiUnsubscribe) orelse return;
        defer c.suil_host_free(host);

        // ExternalUI needs the external-ui host feature so it can notify closure (optional but good)
        var ext_host = LV2_External_UI_Host{ .ui_closed = on_ui_closed }; // set callback if you want
        const ext_host_feat = c.LV2_Feature{
            .URI = "http://kxstudio.sf.net/ns/lv2ext/external-ui#Host",
            .data = &ext_host,
        };

        const lv2_handle = c.lilv_instance_get_handle(self.instance) orelse return error.NoInstanceHandle;

        // Required: instance-access -> pass LV2_Handle from the DSP instance
        const instance_access_feat = c.LV2_Feature{
            .URI = "http://lv2plug.in/ns/ext/instance-access",
            .data = lv2_handle,
        };

        var features: [3]?*const c.LV2_Feature = .{ &ext_host_feat, &instance_access_feat, null };

        var session = UiSession{}; // lives until showUI returns

        const inst = c.suil_instance_new(
            host,
            &session, // controller
            null, // container_type_uri (none for ExternalUI)
            plugin_uri_c,
            ui_uri_c,
            ui_type_uri_c,
            bundle_path_c, // *** filesystem path ***
            binary_path_c, // *** filesystem path ***
            &features,
        ) orelse {
            // suil prints an error already; add context:
            std.log.err("suil_instance_new failed for UI {s} in {s}", .{ cstrZ(ui_uri_c), cstrZ(binary_path_c) });
            return;
        };
        defer c.suil_instance_free(inst);

        // Show and idle the UI (ExternalUI opens its own window)
        // c.suil_instance_show(inst);
        // 1) Get the UI widget and handle from suil
        const widget_ptr = c.suil_instance_get_widget(inst); // void*
        // const ui_handle = c.suil_instance_get_handle(inst); // LV2UI_Handle (void*)

        const ext = asExt(widget_ptr);

        // Show window
        std.debug.print("Show UI\n", .{});
        session.closed.store(false, .seq_cst);
        ext.show.?(ext);
        defer ext.hide.?(ext);

        // Pump until UI tells us it closed
        while (!session.closed.load(.seq_cst)) {
            ext.run.?(ext);
            // std.Thread.sleep(16 * std.time.ns_per_ms); // ~60 Hz tick
            std.Thread.sleep(32 * std.time.ns_per_ms); // ~30 Hz tick
        }
    }

    fn listUIs(self: *Self) !void {
        const plugin = self.plugin;

        const uis = c.lilv_plugin_get_uis(plugin) orelse return error.PluginHasNoUIs;
        if (c.lilv_uis_size(uis) == 0) {
            std.debug.print("Plugin has no UIs.\n", .{});
            return;
        }

        var it = c.lilv_uis_begin(uis);
        var idx: usize = 0;
        while (!c.lilv_uis_is_end(uis, it)) : (it = c.lilv_uis_next(uis, it)) {
            const ui = c.lilv_uis_get(uis, it);
            if (ui == null) continue;

            const ui_uri = c.lilv_ui_get_uri(ui);
            const ui_uri_str = c.lilv_node_as_string(ui_uri);
            std.debug.print("UI #{d}: {s}\n", .{ idx, ui_uri_str });

            // Each UI may have one or more classes
            const classes = c.lilv_ui_get_classes(ui);
            var cit = c.lilv_nodes_begin(classes);
            while (!c.lilv_nodes_is_end(classes, cit)) : (cit = c.lilv_nodes_next(classes, cit)) {
                const cls = c.lilv_nodes_get(classes, cit);
                const cls_str = c.lilv_node_as_string(cls);
                std.debug.print("    class: {s}\n", .{cls_str});
            }

            idx += 1;
        }
    }

    pub fn run(self: *Self, frames: u32) void {
        // _ = self;
        c.lilv_instance_run(self.instance, frames);
        self.midi_sequence.clear();
        // std.debug.print("Test {any}\n", .{self.instance});
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

fn cstrZ(ptr: [*:0]const u8) []const u8 {
    return std.mem.sliceTo(ptr, 0);
}

// Matches SuilWriteFunc
fn uiWrite(
    controller: ?*anyopaque,
    port_index: u32,
    buffer_size: u32,
    protocol: u32,
    buffer: ?*const anyopaque,
) callconv(.c) void {
    _ = controller;
    _ = port_index;
    _ = buffer_size;
    _ = protocol;
    _ = buffer;
}

// Matches SuilPortIndexFunc: uint32_t (*)(SuilController, const char*)
fn uiIndex(controller: ?*anyopaque, port_symbol: [*c]const u8) callconv(.c) u32 {
    _ = controller;
    _ = port_symbol;
    // If you need to compare: std.mem.span(port_symbol) gives you a []const u8 up to first 0
    return 0;
}

// Matches SuilPortSubscribeFunc: uint32_t (*)(SuilController, uint32_t, uint32_t, const LV2_Feature* const*)
fn uiSubscribe(controller: ?*anyopaque, port_index: u32, protocol: u32, features: [*c]const [*c]const c.LV2_Feature) callconv(.c) u32 {
    _ = controller;
    _ = port_index;
    _ = protocol;
    _ = features;
    return 0;
}

fn uiUnsubscribe(controller: ?*anyopaque, port_index: u32, protocol: u32, features: [*c]const [*c]const c.LV2_Feature) callconv(.c) u32 {
    _ = controller;
    _ = port_index;
    _ = protocol;
    _ = features;
    return 0;
}

// Minimal ExternalUI ABI (matches lv2_external_ui.h)
pub const LV2_External_UI_Widget = extern struct {
    run: ?*const fn (?*anyopaque) callconv(.c) void,
    show: ?*const fn (?*anyopaque) callconv(.c) void,
    hide: ?*const fn (?*anyopaque) callconv(.c) void,
};

pub const LV2_External_UI_Host = extern struct {
    ui_closed: ?*const fn (?*anyopaque) callconv(.c) void,
    // Some versions add: ui_resize: ?*const fn (?*anyopaque, c_int, c_int) callconv(.C) c_int,
};

// Feature URI you pass alongside this struct:
pub const EXT_UI_HOST_URI = "http://kxstudio.sf.net/ns/lv2ext/external-ui#Host";

// When you get the widget pointer from suil or lv2ui instantiate:
fn asExternal(widget: ?*anyopaque) *LV2_External_UI_Widget {
    return @ptrCast(widget.?);
}

fn asExt(widget_ptr: ?*anyopaque) *LV2_External_UI_Widget {
    // Assert required alignment, then cast
    const p = widget_ptr orelse @panic("ExternalUI widget is null");

    // 1) Assert the alignment the struct requires
    const aligned: *align(@alignOf(LV2_External_UI_Widget)) anyopaque = @alignCast(p);

    // 2) Now it’s safe to cast to the struct pointer
    return @as(*LV2_External_UI_Widget, @ptrCast(aligned));
}

const UiSession = struct {
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

// Called by the UI when it closes its window
fn on_ui_closed(controller: ?*anyopaque) callconv(.c) void {
    if (controller) |p| {
        const sess: *UiSession = @ptrCast(p);
        sess.closed.store(true, .seq_cst);
    }
}

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

pub fn create_world() ?*c.LilvWorld {
    const world = c.lilv_world_new();
    errdefer c.lilv_world_free(world.?);

    c.lilv_world_load_all(world.?);

    return world;
}

// ---- Tests ----

test "SynthPlugin initialization and deinitialization" {
    // Use the built-in testing allocator
    const allocator = std.testing.allocator;

    const world = create_world();
    try std.testing.expect(world != null);
    defer c.lilv_world_free(world.?);

    c.lilv_world_load_all(world.?);

    // Initialize with a known valid C string literal
    var synth_plugin = try SynthPlugin.init(allocator, world.?, "https://surge-synthesizer.github.io/lv2/surge-xt");
    defer synth_plugin.deinit();
    defer deinitUridTable();

    // synth_plugin.run();

    synth_plugin.midi_sequence.addEvent(0, &[_]u8{ 0x90, 60, 127 });
    synth_plugin.run(256);

    std.debug.print(" {any}\n", .{synth_plugin.audio_out_bufs[5].?[0..100]});

    // Ensure initialization returned a non-null pointer
    // try std.testing.expect(synth_plugin != null);

    // (deinit will run via defer; no double free)

}
