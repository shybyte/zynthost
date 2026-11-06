const std = @import("std");
const host = @import("host.zig");

const c = host.c;

const MidiSequence = @import("midi_sequence.zig").MidiSequence;
const UiSession = @import("ui_session.zig").UiSession;
const Worker = @import("worker.zig").Worker;
const MessageQueue = @import("message_queue.zig").MessageQueue;

const sample_rate: f64 = 48000.0;
pub const max_frames: u32 = 4096;
const atom_buffer_capacity: usize = 65536;

pub const SynthPlugin = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    world: *c.LilvWorld,

    plugin_uri_string: []const u8,
    plugin_uri: *c.LilvNode,
    plugin: *const c.LilvPlugin,
    instance: [*c]c.LilvInstance,

    audio_in_bufs: []?[]f32 = &.{},
    audio_out_bufs: []?[]f32 = &.{},
    audio_ports: std.ArrayList(usize) = .empty,
    atom_inputs: []?MidiSequence = &.{},
    atom_outputs: []?MidiSequence = &.{},
    control_in_vals: []f32 = &.{},
    control_inputs: []bool = &.{},
    control_ports: []bool = &.{},
    control_values: []std.atomic.Value(u32) = &.{},
    midi_sequence: *MidiSequence = undefined,
    worker: Worker = undefined,
    features: [6]?*const c.LV2_Feature = undefined,
    bounded_feature: c.LV2_Feature = .{ .URI = c.LV2_BUF_SIZE__boundedBlockLength, .data = null },
    options_feature: c.LV2_Feature = undefined,
    options: [4]c.LV2_Options_Option = undefined,
    maximum_block_length: i32 = max_frames,
    minimum_block_length: i32 = 1,
    sequence_size: i32 = atom_buffer_capacity,
    ui_requests: MessageQueue = undefined,
    ui_notifications: MessageQueue = undefined,
    event_transfer: u32 = 0,
    atom_chunk: u32 = 0,
    session: ?UiSession = null,

    pub fn init(
        allocator: std.mem.Allocator,
        world: *c.LilvWorld,
        plugin_uri_string: [:0]const u8,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .world = world,
            .plugin_uri_string = try allocator.dupe(u8, plugin_uri_string),
            .plugin_uri = undefined,
            .plugin = undefined,
            .instance = null,
        };
        errdefer allocator.free(self.plugin_uri_string);
        self.plugin_uri = c.lilv_new_uri(world, plugin_uri_string) orelse return error.BadPluginUri;
        errdefer c.lilv_node_free(self.plugin_uri);
        const plugins = c.lilv_world_get_all_plugins(world) orelse return error.NoPlugins;
        self.plugin = c.lilv_plugins_get_by_uri(plugins, self.plugin_uri) orelse return error.PluginNotFound;

        try self.worker.init(allocator);
        errdefer self.worker.deinit(allocator);
        self.ui_requests = try MessageQueue.init(allocator);
        errdefer self.ui_requests.deinit(allocator);
        self.ui_notifications = try MessageQueue.init(allocator);
        errdefer self.ui_notifications.deinit(allocator);

        const lv2_host = host.get();
        self.event_transfer = lv2_host.mapUri(c.LV2_ATOM__eventTransfer);
        self.atom_chunk = lv2_host.mapUri(c.LV2_ATOM__Chunk);
        const int_type = lv2_host.mapUri(c.LV2_ATOM__Int);
        self.options = .{
            .{ .context = c.LV2_OPTIONS_INSTANCE, .subject = 0, .key = lv2_host.mapUri(c.LV2_BUF_SIZE__maxBlockLength), .size = 4, .type = int_type, .value = &self.maximum_block_length },
            .{ .context = c.LV2_OPTIONS_INSTANCE, .subject = 0, .key = lv2_host.mapUri(c.LV2_BUF_SIZE__minBlockLength), .size = 4, .type = int_type, .value = &self.minimum_block_length },
            .{ .context = c.LV2_OPTIONS_INSTANCE, .subject = 0, .key = lv2_host.mapUri(c.LV2_BUF_SIZE__sequenceSize), .size = 4, .type = int_type, .value = &self.sequence_size },
            std.mem.zeroes(c.LV2_Options_Option),
        };
        self.options_feature = .{ .URI = c.LV2_OPTIONS__options, .data = &self.options };
        self.features = .{ &lv2_host.urid_map_feature, &lv2_host.urid_unmap_feature, &self.worker.feature, &self.bounded_feature, &self.options_feature, null };
        try self.checkRequiredFeatures();
        self.instance = c.lilv_plugin_instantiate(self.plugin, sample_rate, &self.features);
        if (self.instance == null) return error.InstanceFailed;
        errdefer {
            self.worker.stop();
            c.lilv_instance_free(self.instance);
        }
        try self.connectPorts();
        errdefer self.freePorts();
        try self.worker.start(self.instance);
        c.lilv_instance_activate(self.instance);
        return self;
    }

    fn checkRequiredFeatures(self: *Self) !void {
        const required = c.lilv_plugin_get_required_features(self.plugin);
        defer c.lilv_nodes_free(required);
        var it = c.lilv_nodes_begin(required);
        while (!c.lilv_nodes_is_end(required, it)) : (it = c.lilv_nodes_next(required, it)) {
            const uri = std.mem.span(c.lilv_node_as_uri(c.lilv_nodes_get(required, it)));
            var supported = false;
            for (self.features) |feature_opt| {
                const feature = feature_opt orelse break;
                if (std.mem.eql(u8, uri, std.mem.span(feature.URI))) supported = true;
            }
            if (!supported) {
                std.log.err("Plugin {s} requires unsupported LV2 feature {s}", .{ self.plugin_uri_string, uri });
                return error.UnsupportedRequiredFeature;
            }
        }
    }

    fn connectPorts(self: *Self) !void {
        const world = self.world;
        const plugin = self.plugin;
        const allocator = self.allocator;
        const lv2_host = host.get();
        const input = c.lilv_new_uri(world, c.LV2_CORE__InputPort);
        const output = c.lilv_new_uri(world, c.LV2_CORE__OutputPort);
        const audio = c.lilv_new_uri(world, c.LV2_CORE__AudioPort);
        const control = c.lilv_new_uri(world, c.LV2_CORE__ControlPort);
        const atom = c.lilv_new_uri(world, c.LV2_ATOM__AtomPort);
        const midi = c.lilv_new_uri(world, c.LV2_MIDI__MidiEvent);
        const minimum_size = c.lilv_new_uri(world, "http://lv2plug.in/ns/ext/resize-port#minimumSize");
        const buffer_type = c.lilv_new_uri(world, c.LV2_ATOM__bufferType);
        const sequence_type = c.lilv_new_uri(world, c.LV2_ATOM__Sequence);
        defer {
            c.lilv_node_free(input);
            c.lilv_node_free(output);
            c.lilv_node_free(audio);
            c.lilv_node_free(control);
            c.lilv_node_free(atom);
            c.lilv_node_free(midi);
            c.lilv_node_free(minimum_size);
            c.lilv_node_free(buffer_type);
            c.lilv_node_free(sequence_type);
        }
        const nports = c.lilv_plugin_get_num_ports(plugin);
        errdefer self.freePorts();
        self.audio_ports = try .initCapacity(allocator, nports);
        self.audio_in_bufs = try allocator.alloc(?[]f32, nports);
        @memset(self.audio_in_bufs, null);
        self.audio_out_bufs = try allocator.alloc(?[]f32, nports);
        @memset(self.audio_out_bufs, null);
        self.atom_inputs = try allocator.alloc(?MidiSequence, nports);
        @memset(self.atom_inputs, null);
        self.atom_outputs = try allocator.alloc(?MidiSequence, nports);
        @memset(self.atom_outputs, null);
        self.control_in_vals = try allocator.alloc(f32, nports);
        @memset(self.control_in_vals, 0);
        self.control_inputs = try allocator.alloc(bool, nports);
        @memset(self.control_inputs, false);
        self.control_ports = try allocator.alloc(bool, nports);
        @memset(self.control_ports, false);
        self.control_values = try allocator.alloc(std.atomic.Value(u32), nports);
        for (self.control_values) |*value| value.* = .init(0);

        var midi_port: ?u32 = null;
        for (0..nports) |index| {
            const p: u32 = @intCast(index);
            const port = c.lilv_plugin_get_port_by_index(plugin, p);
            const is_input = c.lilv_port_is_a(plugin, port, input);
            const is_output = c.lilv_port_is_a(plugin, port, output);
            if (c.lilv_port_is_a(plugin, port, audio)) {
                const buf = try allocator.alloc(f32, max_frames);
                @memset(buf, 0);
                if (is_input) {
                    self.audio_in_bufs[p] = buf;
                } else if (is_output) {
                    self.audio_out_bufs[p] = buf;
                    self.audio_ports.appendAssumeCapacity(p);
                } else {
                    allocator.free(buf);
                    return error.InvalidPortDirection;
                }
                c.lilv_instance_connect_port(self.instance, p, buf.ptr);
            } else if (c.lilv_port_is_a(plugin, port, control)) {
                self.control_inputs[p] = is_input;
                self.control_ports[p] = true;
                var default: ?*c.LilvNode = null;
                c.lilv_port_get_range(plugin, port, &default, null, null);
                defer c.lilv_node_free(default);
                if (default) |node| self.control_in_vals[p] = c.lilv_node_as_float(node);
                self.control_values[p].store(@bitCast(self.control_in_vals[p]), .monotonic);
                c.lilv_instance_connect_port(self.instance, p, &self.control_in_vals[p]);
            } else if (c.lilv_port_is_a(plugin, port, atom)) {
                const types = c.lilv_port_get_value(plugin, port, buffer_type);
                defer c.lilv_nodes_free(types);
                if (!c.lilv_nodes_contains(types, sequence_type)) return error.UnsupportedAtomBufferType;
                const size_node = c.lilv_port_get(plugin, port, minimum_size);
                defer c.lilv_node_free(size_node);
                const requested = if (size_node != null and c.lilv_node_is_int(size_node)) c.lilv_node_as_int(size_node) else 0;
                const capacity = @max(atom_buffer_capacity, @as(usize, @intCast(@max(0, requested))));
                const buffers = if (is_input) self.atom_inputs else self.atom_outputs;
                buffers[p] = try MidiSequence.init(allocator, capacity, lv2_host.mapUri(c.LV2_ATOM__Sequence), lv2_host.mapUri(c.LV2_MIDI__MidiEvent), 0);
                c.lilv_instance_connect_port(self.instance, p, buffers[p].?.seq());
                if (is_input and midi_port == null and c.lilv_port_supports_event(plugin, port, midi)) midi_port = p;
            }
        }
        if (self.audio_ports.items.len < 1 or self.audio_ports.items.len > 2) {
            std.log.err("Expected mono or stereo audio output, found {d}", .{self.audio_ports.items.len});
            return error.UnsupportedAudioPortCount;
        }
        self.midi_sequence = &self.atom_inputs[midi_port orelse return error.NoMidiInputFound].?;
    }

    fn freePorts(self: *Self) void {
        for (self.audio_in_bufs) |buf| {
            if (buf) |b| self.allocator.free(b);
        }
        for (self.audio_out_bufs) |buf| {
            if (buf) |b| self.allocator.free(b);
        }
        for (self.atom_inputs) |*buf| {
            if (buf.*) |*b| b.deinit();
        }
        for (self.atom_outputs) |*buf| {
            if (buf.*) |*b| b.deinit();
        }
        self.allocator.free(self.audio_in_bufs);
        self.allocator.free(self.audio_out_bufs);
        self.allocator.free(self.atom_inputs);
        self.allocator.free(self.atom_outputs);
        self.allocator.free(self.control_in_vals);
        self.allocator.free(self.control_inputs);
        self.allocator.free(self.control_ports);
        self.allocator.free(self.control_values);
        self.audio_ports.deinit(self.allocator);
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
            .control_values = self.control_values,
            .control_ports = self.control_ports,
            .requests = &self.ui_requests,
            .event_transfer = self.event_transfer,
        });
    }

    pub fn run(self: *Self, frames: u32) void {
        std.debug.assert(frames <= max_frames);
        self.applyUiMessages();
        for (self.atom_outputs) |*buffer| {
            if (buffer.*) |*sequence| {
                sequence.seq().atom = .{ .size = @intCast(sequence.buf.len - @sizeOf(c.LV2_Atom)), .type = self.atom_chunk };
            }
        }
        self.worker.deliverResponses();
        c.lilv_instance_run(self.instance, frames);
        self.worker.endRun();
        for (self.control_ports, 0..) |is_control, port| {
            if (is_control) self.control_values[port].store(@bitCast(self.control_in_vals[port]), .monotonic);
        }
        for (self.atom_inputs) |*buffer| {
            if (buffer.*) |*sequence| sequence.clear();
        }
        self.collectNotifications();
    }

    fn applyUiMessages(self: *Self) void {
        for (0..MessageQueue.capacity) |_| {
            const message = self.ui_requests.peek() orelse break;
            defer self.ui_requests.pop();
            if (message.port >= self.control_in_vals.len) continue;
            if (message.protocol == 0 and message.size == @sizeOf(f32) and self.control_inputs[message.port]) {
                self.control_in_vals[message.port] = std.mem.bytesToValue(f32, message.bytes()[0..4]);
            } else if (message.protocol == self.event_transfer) {
                if (self.atom_inputs[message.port]) |*sequence| {
                    sequence.addAtom(0, message.bytes()) catch {};
                }
            }
        }
    }

    fn collectNotifications(self: *Self) void {
        for (self.atom_outputs, 0..) |*buffer, port| {
            const sequence = if (buffer.*) |*s| s else continue;
            const header = sequence.seq().atom;
            if (header.type != sequence.atom_sequence_urid or header.size < 8 or header.size > sequence.buf.len - 8) continue;
            const end: usize = @as(usize, header.size) + 8;
            var offset: usize = @sizeOf(c.LV2_Atom_Sequence);
            while (offset + @sizeOf(c.LV2_Atom_Event) <= end) {
                const event = std.mem.bytesToValue(c.LV2_Atom_Event, sequence.buf[offset..][0..@sizeOf(c.LV2_Atom_Event)]);
                const size = @as(usize, event.body.size) + @sizeOf(c.LV2_Atom);
                if (size > end - offset - 8) break;
                _ = self.ui_notifications.push(@intCast(port), self.event_transfer, sequence.buf[offset + 8 ..][0..size]);
                offset += 8 + std.mem.alignForward(usize, size, 8);
            }
        }
    }

    /// Call only on the UI thread; the audio thread only copies notification data.
    pub fn pumpUI(self: *Self) void {
        if (self.session) |*session| session.pump();
        for (0..MessageQueue.capacity) |_| {
            const message = self.ui_notifications.peek() orelse break;
            if (self.session) |*session| session.portEvent(message.port, message.protocol, message.bytes());
            self.ui_notifications.pop();
        }
    }

    pub fn saveState(self: *Self, file_path: [:0]const u8) !void {
        const lv2_host = host.get();
        const dir = try self.allocator.dupeSentinel(u8, std.fs.path.dirname(file_path) orelse "", 0);
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
            &self.features, // Host features, including this instance’s worker
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

    pub fn loadState(self: *Self, io: std.Io, file_path: [:0]const u8) !void {
        const lv2_host = host.get();
        const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
        defer file.close(io);

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
            &self.features,
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

        // Stop and join while the plugin handle is still alive.
        self.worker.deinit(self.allocator);
        c.lilv_instance_deactivate(self.instance);
        c.lilv_instance_free(self.instance);
        c.lilv_node_free(self.plugin_uri);
        self.freePorts();
        self.ui_requests.deinit(self.allocator);
        self.ui_notifications.deinit(self.allocator);

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

    // Bounds-checked write into the buffer already connected to the plugin
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
    try synth_plugin.loadState(std.testing.io, "patches/tmp/patch.ttl");

    try std.testing.expectEqual(2, synth_plugin.audio_ports.items.len);
    try std.testing.expectEqual(5, synth_plugin.audio_ports.items[0]);
    try std.testing.expectEqual(6, synth_plugin.audio_ports.items[1]);

    try synth_plugin.midi_sequence.addEvent(0, &[_]u8{ 0x90, 60, 127 });
    synth_plugin.run(256);

    std.debug.print(" {any}\n", .{synth_plugin.audio_out_bufs[5].?[0..100]});

    const file_name = "patches/tmp/test-plugin-patch.json";
    try synth_plugin.saveState(file_name);
    try synth_plugin.loadState(std.testing.io, file_name);
}

test "Nori prepares lyrics through the worker, sends notifications, plays mono MIDI, and restores state" {
    const allocator = std.testing.allocator;
    const lv2_host = try host.initGlobal(allocator);
    defer host.deinitGlobal();
    const plugin = SynthPlugin.init(allocator, lv2_host.worldPtr(), "urn:nori:singing-voice") catch |err| switch (err) {
        error.PluginNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer plugin.deinit();
    try std.testing.expectEqual(1, plugin.audio_ports.items.len);
    try std.testing.expect(plugin.midi_sequence.buf.len >= 32768);
    try std.testing.expect(plugin.atom_outputs[2].?.buf.len >= 32768);
    try std.testing.expectEqual(0, plugin.midi_sequence.seq().body.unit);

    // Exercise the same callbacks and queues used by the real UI, without a display.
    var session = UiSession{ .ctx = .{
        .allocator = allocator,
        .world = plugin.world,
        .plugin_uri_string = plugin.plugin_uri_string,
        .plugin_uri = plugin.plugin_uri,
        .plugin = plugin.plugin,
        .instance = plugin.instance,
        .control_values = plugin.control_values,
        .control_ports = plugin.control_ports,
        .requests = &plugin.ui_requests,
        .event_transfer = plugin.event_transfer,
    } };
    try std.testing.expectEqual(3, UiSession.uiIndex(&session, "gain"));
    try std.testing.expectEqual(c.LV2UI_INVALID_PORT_INDEX, UiSession.uiIndex(&session, "missing"));
    var buffer: [4096]u8 align(8) = undefined;
    const patch = testPatchSet(lv2_host, &buffer, "urn:nori:singing-voice#lyrics", "Hello world");
    UiSession.uiWrite(&session, 0, @intCast(patch.len), plugin.event_transfer, patch.ptr);
    try waitForTestProperty(plugin, lv2_host, "urn:nori:singing-voice#phonemes", "HH AH0 / L OW1 | W ER1 L D\x00");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_path = try std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/nori.ttl", .{tmp.sub_path}, 0);
    defer allocator.free(state_path);
    try plugin.saveState(state_path);
    const edited = testPatchSet(lv2_host, &buffer, "urn:nori:singing-voice#phonemes", "S IY1 / _");
    UiSession.uiWrite(&session, 0, @intCast(edited.len), plugin.event_transfer, edited.ptr);
    try waitForTestProperty(plugin, lv2_host, "urn:nori:singing-voice#phonemes", "S IY1 / _\x00");
    try plugin.loadState(std.testing.io, state_path);
    try waitForTestProperty(plugin, lv2_host, "urn:nori:singing-voice#source", "Hello world\x00");

    const gain: f32 = -6;
    UiSession.uiWrite(&session, 3, 4, 0, &gain);
    try plugin.midi_sequence.addEvent(13, &.{ 0x90, 60, 127 });
    plugin.run(1024);
    try std.testing.expectEqual(-6, plugin.control_in_vals[3]);
    const audio = plugin.audio_out_bufs[plugin.audio_ports.items[0]].?;
    try std.testing.expectEqualSlices(f32, &(@as([13]f32, @splat(0))), audio[0..13]);
    var energy: f32 = 0;
    for (audio[13..1024]) |sample| energy += sample * sample;
    try std.testing.expect(energy > 0.001);
}

fn testPatchSet(lv2_host: *host.Lv2Host, buffer: []u8, key: [:0]const u8, text: []const u8) []const u8 {
    var forge: c.LV2_Atom_Forge = undefined;
    c.lv2_atom_forge_init(&forge, lv2_host.uridMap());
    c.lv2_atom_forge_set_buffer(&forge, buffer.ptr, buffer.len);
    var frame: c.LV2_Atom_Forge_Frame = undefined;
    _ = c.lv2_atom_forge_object(&forge, &frame, 0, lv2_host.mapUri("http://lv2plug.in/ns/ext/patch#Set"));
    _ = c.lv2_atom_forge_key(&forge, lv2_host.mapUri("http://lv2plug.in/ns/ext/patch#property"));
    _ = c.lv2_atom_forge_urid(&forge, lv2_host.mapUri(key));
    _ = c.lv2_atom_forge_key(&forge, lv2_host.mapUri("http://lv2plug.in/ns/ext/patch#value"));
    _ = c.lv2_atom_forge_string(&forge, text.ptr, @intCast(text.len));
    c.lv2_atom_forge_pop(&forge, &frame);
    const atom = std.mem.bytesToValue(c.LV2_Atom, buffer[0..8]);
    return buffer[0 .. @as(usize, atom.size) + 8];
}

fn waitForTestProperty(plugin: *SynthPlugin, lv2_host: *host.Lv2Host, key: [:0]const u8, expected: []const u8) !void {
    const property_id = lv2_host.mapUri("http://lv2plug.in/ns/ext/patch#property");
    const value_id = lv2_host.mapUri("http://lv2plug.in/ns/ext/patch#value");
    const key_id = lv2_host.mapUri(key);
    for (0..1000) |_| {
        plugin.run(1);
        while (plugin.ui_notifications.peek()) |message| {
            defer plugin.ui_notifications.pop();
            if (plugin.session) |*session| session.portEvent(message.port, message.protocol, message.bytes());
            try std.testing.expectEqual(2, message.port);
            try std.testing.expectEqual(plugin.event_transfer, message.protocol);
            const data = message.bytes();
            if (data.len < 16) continue;
            var actual_key: u32 = 0;
            var actual_value: []const u8 = &.{};
            var offset: usize = 16;
            while (offset + 16 <= data.len) {
                const property = std.mem.bytesToValue(c.LV2_Atom_Property_Body, data[offset..][0..16]);
                if (property.value.size > data.len - offset - 16) break;
                const value = data[offset + 16 ..][0..property.value.size];
                if (property.key == property_id and value.len == 4) actual_key = std.mem.bytesToValue(u32, value[0..4]);
                if (property.key == value_id) actual_value = value;
                offset += 16 + std.mem.alignForward(usize, property.value.size, 8);
            }
            if (actual_key == key_id and std.mem.eql(u8, actual_value, expected)) return;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.NotificationTimedOut;
}

test "Nori GTK3 editor loads lyrics, applies phoneme edits, and resets through the host" {
    if (c.gtk_init_check(null, null) == 0) return error.SkipZigTest;
    const lv2_host = try host.initGlobal(std.testing.allocator);
    defer host.deinitGlobal();
    const plugin = SynthPlugin.init(std.testing.allocator, lv2_host.worldPtr(), "urn:nori:singing-voice") catch |err| switch (err) {
        error.PluginNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer plugin.deinit();
    try plugin.showUI();
    const root = plugin.session.?.gtk_widget.?;
    var skip: usize = 1;
    const phoneme_view = findTestWidget(root, "GtkTextView", null, &skip) orelse return error.PhonemeEditorNotFound;
    try waitForEditorText(plugin, phoneme_view, "AA1");
    skip = 0;
    const lyrics_button = findTestWidget(root, "GtkButton", "Load English lyrics", &skip) orelse return error.LyricsButtonNotFound;
    c.gtk_button_clicked(@ptrCast(lyrics_button));
    try waitForEditorText(plugin, phoneme_view, "HH AH0 / L OW1 | W ER1 L D");

    const text_buffer = c.gtk_text_view_get_buffer(@ptrCast(phoneme_view));
    c.gtk_text_buffer_set_text(text_buffer, "  S   IY1  /  _  ", -1);
    skip = 0;
    const apply_button = findTestWidget(root, "GtkButton", "Apply edited phonemes", &skip) orelse return error.PhonemeButtonNotFound;
    c.gtk_button_clicked(@ptrCast(apply_button));
    try waitForTestProperty(plugin, lv2_host, "urn:nori:singing-voice#phonemes", "S IY1 / _\x00");
    // Nori keeps the original editable source, including its whitespace.
    try waitForEditorText(plugin, phoneme_view, "  S   IY1  /  _  ");

    try plugin.midi_sequence.addEvent(0, &.{ 0x90, 60, 100 });
    plugin.run(1024);
    plugin.pumpUI();
    skip = 0;
    const reset_button = findTestWidget(root, "GtkButton", "Reset phrase", &skip) orelse return error.ResetButtonNotFound;
    c.gtk_button_clicked(@ptrCast(reset_button));
    const reset_cursor: i32 = -1;
    try waitForTestProperty(plugin, lv2_host, "urn:nori:singing-voice#cursor", std.mem.asBytes(&reset_cursor));
}

fn findTestWidget(widget: *c.GtkWidget, name: []const u8, label: ?[]const u8, skip: *usize) ?*c.GtkWidget {
    if (std.mem.eql(u8, std.mem.span(c.gtk_widget_get_name(widget)), name)) {
        const label_matches = if (label) |text| std.mem.eql(u8, std.mem.span(c.gtk_button_get_label(@ptrCast(widget))), text) else true;
        if (label_matches) {
            if (skip.* == 0) return widget;
            skip.* -= 1;
        }
    }
    if (c.g_type_check_instance_is_a(@ptrCast(widget), c.gtk_container_get_type()) == 0) return null;
    const children = c.gtk_container_get_children(@ptrCast(widget));
    defer c.g_list_free(children);
    var child = children;
    while (child != null) : (child = child.*.next) {
        if (findTestWidget(@ptrCast(@alignCast(child.*.data)), name, label, skip)) |found| return found;
    }
    return null;
}

fn waitForEditorText(plugin: *SynthPlugin, view: *c.GtkWidget, expected: []const u8) !void {
    const buffer = c.gtk_text_view_get_buffer(@ptrCast(view));
    for (0..1000) |_| {
        plugin.run(1);
        plugin.pumpUI();
        UiSession.pumpGtkEvents();
        var start: c.GtkTextIter = undefined;
        var end: c.GtkTextIter = undefined;
        c.gtk_text_buffer_get_bounds(buffer, &start, &end);
        const text = c.gtk_text_buffer_get_text(buffer, &start, &end, 0);
        defer c.g_free(text);
        if (std.mem.eql(u8, std.mem.span(text), expected)) return;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.EditorUpdateTimedOut;
}
