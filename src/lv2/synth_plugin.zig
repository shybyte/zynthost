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
    audio_ports: std.ArrayList(usize),

    control_in_vals: []f32,
    backing: [1024]u8 align(8),
    midi_sequence: MidiSequence,

    session: UiSession,

    pub fn init(
        allocator: std.mem.Allocator,
        world: *c.LilvWorld,
        plugin_uri_string: [*:0]const u8, // already a valid C string
    ) !*Self {
        const self = try allocator.create(SynthPlugin);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.world = world;
        self.audio_ports = try std.ArrayList(usize).initCapacity(allocator, 100);

        const plugins = c.lilv_world_get_all_plugins(world);
        if (plugins == null) return error.NoPlugins;

        self.plugin_uri = c.lilv_new_uri(world, plugin_uri_string) orelse return error.BadPluginUri;
        self.plugin = c.lilv_plugins_get_by_uri(plugins, self.plugin_uri) orelse return error.PluginNotFound;

        self.instance = c.lilv_plugin_instantiate(self.plugin, sample_rate, &urid_map_features);
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
        const atom_Sequence_urid = urid_map_func(null, "http://lv2plug.in/ns/ext/atom#Sequence");
        const midi_MidiEvent_urid = urid_map_func(null, "http://lv2plug.in/ns/ext/midi#MidiEvent");
        const midi_timeframe_urid = urid_map_func(null, "http://lv2plug.in/ns/ext/time#frame");

        self.midi_sequence = MidiSequence.init(self.backing[0..], atom_Sequence_urid, midi_MidiEvent_urid, midi_timeframe_urid);
        // try self.midi_sequence.addEvent(0, &[_]u8{ 0x90, 60, 127 });

        // Connect the MIDI sequence to the discovered MIDI input port
        c.lilv_instance_connect_port(self.instance, midi_in_port_index.?, self.midi_sequence.seq());
    }

    pub fn showUI(self: *Self) !*UiSession {
        self.session.plugin = self;
        try self.session.init();
        return &self.session;
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

    pub fn saveState(self: *Self, file_path: []const u8) !void {
        const dir = try std.heap.page_allocator.dupeZ(u8, std.fs.path.dirname(file_path) orelse "");

        std.debug.print("saveState {s} {s}\n", .{ dir, file_path });

        const state = c.lilv_state_new_from_instance(
            self.plugin,
            self.instance,
            &urid_map, // LV2_URID_Map*
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
            &urid_map,
            &urid_un_map,
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
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("File '{s}' does not exist.\n", .{file_path});
                return;
            },
            else => return err, // propagate other errors
        };
        defer file.close();

        const state = c.lilv_state_new_from_file(
            self.world,
            &urid_map,
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

        c.lilv_node_free(self.plugin_uri);
        c.lilv_instance_deactivate(self.instance);
        c.lilv_instance_free(self.instance);
        self.allocator.destroy(self);
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
    const float_id = urid_map_func(null, "http://lv2plug.in/ns/ext/atom#Float");
    // _ = port_symbol;
    value_type.* = float_id;
    size.* = @sizeOf(f32);
    return &zero;
    // value_type.* = 0;
    // size.* = 0;
    // return null;
}

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
    // _ = port_index;
    // _ = buffer_size;
    // _ = protocol;
    // _ = buffer;
    std.debug.print("uiWrite portIndex {} {} {} {?}\n", .{ port_index, protocol, buffer_size, buffer });

    const sess: *UiSession = @ptrCast(@alignCast(controller));
    const plugin = sess.*.plugin;
    // Bounds check
    if (port_index < plugin.control_in_vals.len and protocol == 0 and buffer != null and buffer_size == @sizeOf(f32)) {
        const fptr: *const f32 = @ptrCast(@alignCast(buffer.?));
        plugin.control_in_vals[port_index] = fptr.*;
        std.debug.print("New val: {}\n", .{fptr.*});
        // No need to reconnect; pointer is stable.
        // If you want to observe changes:
        // std.debug.print("UI wrote port {} = {d}\n", .{ port_index, fptr.* });
        return;
    }
}

// Matches SuilPortIndexFunc: uint32_t (*)(SuilController, const char*)
fn uiIndex(controller: ?*anyopaque, port_symbol: [*c]const u8) callconv(.c) u32 {
    _ = controller;
    // _ = port_symbol;
    // If you need to compare: std.mem.span(port_symbol) gives you a []const u8 up to first 0
    std.debug.print("uiIndex port_symbol {s}\n", .{port_symbol});
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

pub const UiSession = struct {
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    plugin: *SynthPlugin,
    ext: *LV2_External_UI_Widget,
    suil_instance: *c.SuilInstance,

    host: *c.SuilHost,
    ext_host: LV2_External_UI_Host,
    ext_host_feat: c.LV2_Feature,
    instance_access_feat: c.LV2_Feature,
    features: [3]?*const c.LV2_Feature,

    pub fn init(self: *UiSession) !void {
        const synth_plugin = self.plugin;
        const world = synth_plugin.world;
        const plugin = synth_plugin.plugin;

        const ext_ui_class = c.lilv_new_uri(world, "http://kxstudio.sf.net/ns/lv2ext/external-ui#Widget");
        // defer c.lilv_node_free(ext_ui_class);

        try synth_plugin.listUIs();

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
        if (ui == null) return error.NoExternalUiFound;

        // Required strings
        const plugin_uri_c = c.lilv_node_as_uri(synth_plugin.plugin_uri); // plugin URI
        const ui_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_uri(ui.?)); // selected UI URI
        const ui_type_uri_c = "http://kxstudio.sf.net/ns/lv2ext/external-ui#Widget";

        // Convert bundle/bin URIs → filesystem paths
        const binary_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_binary_uri(ui.?)) orelse return error.SomeError;
        const binary_path_c = try utils.convertUritoPath(synth_plugin.allocator, binary_uri_c);
        defer synth_plugin.allocator.free(binary_path_c);
        std.debug.print("binary_path_c {s}\n", .{binary_path_c});

        const bundle_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_bundle_uri(ui.?)) orelse return error.SomeError;
        const bundle_path_c = try utils.convertUritoPath(synth_plugin.allocator, bundle_uri_c);
        defer synth_plugin.allocator.free(bundle_path_c);
        std.debug.print("bundle_path_c {s}\n", .{bundle_path_c});

        // suil host
        self.host = c.suil_host_new(uiWrite, uiIndex, uiSubscribe, uiUnsubscribe) orelse return error.SomeError;
        errdefer c.suil_host_free(self.host);

        // ExternalUI needs the external-ui host feature so it can notify closure (optional but good)
        self.ext_host = LV2_External_UI_Host{ .ui_closed = on_ui_closed }; // set callback if you want
        self.ext_host_feat = c.LV2_Feature{
            .URI = "http://kxstudio.sf.net/ns/lv2ext/external-ui#Host",
            .data = &self.ext_host,
        };

        const lv2_handle = c.lilv_instance_get_handle(synth_plugin.instance) orelse return error.NoInstanceHandle;

        // Required: instance-access -> pass LV2_Handle from the DSP instance
        self.instance_access_feat = c.LV2_Feature{
            .URI = "http://lv2plug.in/ns/ext/instance-access",
            .data = lv2_handle,
        };

        self.features = .{ &self.ext_host_feat, &self.instance_access_feat, null };

        const suil_instance = c.suil_instance_new(
            self.host,
            self, // controller
            null, // container_type_uri (none for ExternalUI)
            plugin_uri_c,
            ui_uri_c,
            ui_type_uri_c,
            bundle_path_c, // *** filesystem path ***
            binary_path_c, // *** filesystem path ***
            &self.features,
        ) orelse {
            // suil prints an error already; add context:
            std.log.err("suil_instance_new failed for UI {s} in {s}", .{ cstrZ(ui_uri_c), cstrZ(binary_path_c) });
            return error.SomeError;
        };
        errdefer c.suil_instance_free(suil_instance);

        self.suil_instance = suil_instance;

        const widget_ptr = c.suil_instance_get_widget(suil_instance); // void*

        const ext = asExt(widget_ptr);
        self.ext = ext;

        // Show window
        std.debug.print("Show UI\n", .{});
        self.closed.store(false, .seq_cst);
        ext.show.?(ext);
    }

    pub fn isClosed(self: *UiSession) bool {
        return self.closed.load(.seq_cst);
    }

    pub fn deinit(self: *UiSession) void {
        c.suil_host_free(self.host);
        c.suil_instance_free(self.suil_instance);

        const ext = self.ext;
        ext.hide.?(ext);

        std.debug.print("UI Closed\n", .{});
    }
};

// Called by the UI when it closes its window
fn on_ui_closed(controller: ?*anyopaque) callconv(.c) void {
    if (controller) |p| {
        const sess: *UiSession = @ptrCast(@alignCast(p));
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

    // std.debug.print("urid_map_func {s}\n", .{uri.?});

    if (table_inited) {
        if (uri_table.get(s)) |found| return found;
        // Copy the key because s points to plugin/lilv-owned memory
        const dup = std.heap.page_allocator.dupeZ(u8, s) catch return 0;
        const id: c_uint = next_urid;
        next_urid += 1;
        _ = uri_table.put(dup, id) catch return 0;
        // std.debug.print("urid_map_func return  {s} {}\n", .{ uri.?, id });
        return id;
    } else {
        // Fallback linear counter if somehow called before init
        const id2: c_uint = next_urid;
        next_urid += 1;
        return id2;
    }
}

export fn urid_unmap_func(handle: ?*anyopaque, urid: c.LV2_URID) callconv(.c) ?[*:0]const u8 {
    _ = handle;
    if (!table_inited) return null;

    var it = uri_table.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == urid) {
            // The key we stored is a dup’d string; ensure it is NUL-terminated
            // If you used dupeZ, you can safely cast:
            const z: [:0]const u8 = @ptrCast(entry.key_ptr.*);
            return z.ptr;
        }
    }
    return null;
}

var urid_map: c.LV2_URID_Map = .{
    .handle = null,
    .map = urid_map_func,
};

var urid_un_map: c.LV2_URID_Unmap = .{
    .handle = null,
    .unmap = urid_unmap_func,
};

var urid_map_feature: c.LV2_Feature = .{
    .URI = "http://lv2plug.in/ns/ext/urid#map",
    .data = &urid_map,
};

var urid_map_features = [_]?*const c.LV2_Feature{
    &urid_map_feature,
    null, // terminator
};

var world_global: *c.LilvWorld = undefined;

pub fn create_world(allocator: std.mem.Allocator) !*c.LilvWorld {
    world_global = c.lilv_world_new() orelse return error.LilvWorldNewFailed;
    errdefer free_world();

    c.lilv_world_load_all(world_global);

    try initUridTable(allocator); // initializes global URI→URID map used by the C callback

    return world_global;
}

pub fn free_world() void {
    c.lilv_world_free(world_global);
    deinitUridTable();
}

fn listPlugins(world: *c.LilvWorld) void {
    const plugins = c.lilv_world_get_all_plugins(world);
    if (plugins == null) {
        std.debug.print("No LV2 plugins found\n", .{});
        c.lilv_world_free(world);
        return;
    }

    const iter = c.lilv_plugins_begin(plugins);
    var it = iter;

    while (!c.lilv_plugins_is_end(plugins, it)) : (it = c.lilv_plugins_next(plugins, it)) {
        const plugin = c.lilv_plugins_get(plugins, it);
        if (plugin == null) continue;

        // --- URI ---
        const uri_c = c.lilv_node_as_string(c.lilv_plugin_get_uri(plugin));
        if (uri_c != null) {
            std.debug.print("URI: {s}\n", .{std.mem.span(uri_c)});
        } else {
            std.debug.print("URI: (unknown)\n", .{});
        }

        // --- Name ---
        const name_node = c.lilv_plugin_get_name(plugin);
        if (name_node != null) {
            const name_c = c.lilv_node_as_string(name_node);
            std.debug.print("  Name: {s}\n", .{std.mem.span(name_c)});
        } else {
            std.debug.print("  Name: Unknown\n", .{});
        }

        // --- Class label ---
        const class_ptr = c.lilv_plugin_get_class(plugin);
        if (class_ptr != null) {
            const label_node = c.lilv_plugin_class_get_label(class_ptr);
            if (label_node != null) {
                const label_c = c.lilv_node_as_string(label_node);
                std.debug.print("  Class: {s}\n", .{std.mem.span(label_c)});
            } else {
                std.debug.print("  Class: Unknown\n", .{});
            }
        } else {
            std.debug.print("  Class: Unknown\n", .{});
        }

        // --- Library (shared object) URI and best-effort file path ---
        const lib_node = c.lilv_plugin_get_library_uri(plugin);
        if (lib_node != null) {
            const lib_uri_c = c.lilv_node_as_string(lib_node);
            const lib_uri = std.mem.span(lib_uri_c);
            std.debug.print("  Library URI: {s}\n", .{lib_uri});

            // Best-effort path view if it's a file:// URI (no percent-decoding here).
            if (std.mem.startsWith(u8, lib_uri, "file://")) {
                const path = lib_uri["file://".len..];
                std.debug.print("  Library Path (best-effort): {s}\n", .{path});
            }
        } else {
            std.debug.print("  Library: (unknown)\n", .{});
        }

        std.debug.print("\n", .{});
    }
}
// ---- Tests ----

test "SynthPlugin initialization and deinitialization" {
    const allocator = std.testing.allocator;

    const world = try create_world(allocator);
    defer free_world();

    // listPlugins(world.?);

    // Initialize with a known valid C string literal
    var synth_plugin = try SynthPlugin.init(allocator, world, "https://surge-synthesizer.github.io/lv2/surge-xt");
    defer synth_plugin.deinit();

    try synth_plugin.saveState("patches/tmp/patch.ttl");
    try synth_plugin.loadState("patches/tmp/patch.ttl");

    try std.testing.expectEqual(2, synth_plugin.audio_ports.items.len);
    try std.testing.expectEqual(5, synth_plugin.audio_ports.items[0]);
    try std.testing.expectEqual(6, synth_plugin.audio_ports.items[1]);

    synth_plugin.midi_sequence.addEvent(0, &[_]u8{ 0x90, 60, 127 });
    synth_plugin.run(256);

    std.debug.print(" {any}\n", .{synth_plugin.audio_out_bufs[5].?[0..100]});

    // const file_name = "/tmp/saved-plugin-state.json";
    // try synth_plugin.saveState(file_name);
    // try synth_plugin.loadState(file_name);
}
