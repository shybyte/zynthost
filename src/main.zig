const std = @import("std");

const synth_plugin_mod = @import("lv2/synth_plugin.zig");
const lv2_host = @import("lv2/host.zig");
const SynthPlugin = synth_plugin_mod.SynthPlugin;
const MidiInput = @import("./midi_input.zig").MidiInput;
const MidiMessage = @import("./midi.zig").MidiMessage;
const audio_output = @import("./audio_output.zig");
const patch_mod = @import("./patch.zig");
const AppConfig = @import("./config.zig").AppConfig;
const utils = @import("./utils.zig");
const UiSession = @import("lv2/ui_session.zig").UiSession;

const Channel = struct {
    midi_channel: u4,
    config: *const patch_mod.ChannelConfig,
    plugin: *SynthPlugin,
};

// pseudo "message queue" to get program changes from audioCallback into main
var new_midi_program = std.atomic.Value(u8).init(0);

const inactivity_timeout_ms: i64 = std.time.ms_per_s * 60;
var last_midi_event_ms = std.atomic.Value(i64).init(0);

pub fn main(init: std.process.Init) !void {
    std.debug.print("Starting Zynthost...\n", .{});

    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const patch_set_path = if (args.len == 2) args[1] else return error.MissingPatchSetFileName;

    std.debug.print("Load patch set {s} ...", .{patch_set_path});
    const patch_set = try patch_mod.PatchSet.load(allocator, io, patch_set_path);
    defer patch_set.deinit();
    std.debug.print(" successfully.", .{});
    const show_ui = patch_set.value.show_ui orelse true;

    const app_config = try AppConfig.loadWithFallback(allocator, io);
    defer app_config.deinit();
    var midi_input = try MidiInput.init(allocator, app_config.value.midi_name_filter);
    defer midi_input.deinit();

    const host_instance = try lv2_host.initGlobal(allocator);
    defer lv2_host.deinitGlobal();
    const world = host_instance.worldPtr();

    var midi_program = patch_set.value.patches[0].program;
    new_midi_program.store(midi_program, .seq_cst);

    var quit = false;
    while (!quit) {
        const patch = try patch_set.value.loadPatch(allocator, io, midi_program);
        defer patch.deinit();

        var channels = try std.ArrayList(Channel).initCapacity(allocator, patch.channels().len);
        defer channels.deinit(allocator);
        for (patch.channels(), 0..) |*channel, i| {
            if (channel.plugins.len == 0) continue;
            const plugin = try SynthPlugin.init(allocator, world, channel.plugins[0].uri);

            const plugin_patch_file_name = try patch_mod.get_plugin_patch_file_name(allocator, patch.path, @intCast(i));
            defer allocator.free(plugin_patch_file_name);
            plugin.loadState(io, plugin_patch_file_name) catch |err| {
                if (err != error.FileNotFound) {
                    std.log.warn("Failed to load plugin state {s}: {s}", .{ plugin_patch_file_name, @errorName(err) });
                }
            };

            channels.appendAssumeCapacity(.{
                .config = channel,
                .midi_channel = @intCast(i),
                .plugin = plugin,
            });
        }
        defer {
            for (channels.items) |channel| {
                channel.plugin.deinit();
            }
        }

        var audio_callback_user_data = AudioCallbackUserData{
            .io = io,
            .patch_config = &patch.config.value,
            .channels = channels.items,
            .midi_input = &midi_input,
        };
        last_midi_event_ms.store(std.Io.Clock.awake.now(io).toMilliseconds(), .seq_cst);
        try audio_output.startAudio(&audio_callback_user_data, audioCallback);
        defer audio_output.stopAudio();

        if (show_ui) {
            for (channels.items) |channel| {
                try channel.plugin.showUI();
            }
        }

        const stdin_file = std.Io.File.stdin();
        var read_buffer: [1024]u8 = undefined;
        var reader = stdin_file.reader(io, &read_buffer);

        while (true) {
            UiSession.pumpGtkEvents();
            for (channels.items) |channel| channel.plugin.pumpUI();

            if (shouldQuitOnUiClose(patch_set.value.exit_on_last_ui_closed, channels.items)) {
                quit = true;
                break;
            }

            if (audio_output.isRunning()) {
                if ((std.Io.Clock.awake.now(io).toMilliseconds() - last_midi_event_ms.load(.seq_cst)) >= inactivity_timeout_ms) {
                    audio_output.stopAudio();
                }
            } else {
                var has_ui_events = false;
                for (channels.items) |channel| {
                    has_ui_events = has_ui_events or channel.plugin.ui_requests.hasMessages();
                }
                if (midi_input.has_new_events() or has_ui_events) {
                    last_midi_event_ms.store(std.Io.Clock.awake.now(io).toMilliseconds(), .seq_cst);
                    try audio_output.startAudio(&audio_callback_user_data, audioCallback);
                    continue;
                }
            }

            if (pollProgramChange(&midi_program, &patch_set.value)) break;

            if (reader.interface.bufferedLen() == 0 and !try utils.fileHasInput(stdin_file)) {
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            }

            const command = try readCommand(&reader.interface) orelse {
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            };
            std.debug.print("You entered: \"{s}\"\n", .{command});

            if (std.mem.eql(u8, command, "s")) {
                std.debug.print("Saving ... \n", .{});
                try saveChannelStates(allocator, channels.items, patch.path);
            } else if (std.mem.eql(u8, command, "q")) {
                quit = true;
                break;
            }
        }
    }

    std.debug.print("Finished.\n", .{});
}

fn readCommand(reader: *std.Io.Reader) !?[]const u8 {
    const line = try reader.takeDelimiter('\n') orelse return null;
    return std.mem.trimEnd(u8, line, "\r");
}

fn shouldQuitOnUiClose(enabled: bool, channels: []const Channel) bool {
    if (!enabled) return false;

    var had_ui = false;
    for (channels) |channel| {
        if (channel.plugin.session) |*session| {
            had_ui = true;
            if (!session.isClosed()) return false;
        }
    }
    // Headless patches and plugins without a UI must keep running.
    return had_ui;
}

const AudioCallbackUserData = struct {
    io: std.Io,
    patch_config: *const patch_mod.PatchConfig,
    channels: []Channel,
    midi_input: *MidiInput,
};

fn audioCallback(
    input: ?*const anyopaque,
    output: ?*anyopaque,
    frame_count: c_ulong,
    time_info: [*c]const audio_output.PaStreamCallbackTimeInfo,
    status_flags: audio_output.PaStreamCallbackFlags,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = input;
    _ = time_info;
    _ = status_flags;

    const data: *AudioCallbackUserData = @ptrCast(@alignCast(user_data.?));
    const out: [*]f32 = @ptrCast(@alignCast(output));
    const frame_count_usize: usize = @intCast(frame_count);

    const midi_events = data.midi_input.poll();

    for (midi_events) |midi_event| {
        if (midi_event.program()) |program| {
            new_midi_program.store(program, .seq_cst);
        }
    }

    for (data.channels) |*channel| {
        routeMidiEvents(data.io, channel, midi_events);
    }

    // PortAudio can supply larger buffers than our plugins' advertised limit.
    // MIDI belongs to the first chunk and is cleared by SynthPlugin.run().
    var offset: usize = 0;
    while (offset < frame_count_usize) {
        const count = @min(frame_count_usize - offset, synth_plugin_mod.max_frames);
        for (data.channels) |channel| channel.plugin.run(@intCast(count));
        mixFrames(out[offset * 2 ..][0 .. count * 2], count, data.channels, data.patch_config.volume);
        offset += count;
    }

    return audio_output.paContinue;
}

fn routeMidiEvents(io: std.Io, channel: *Channel, midi_events: []const MidiMessage) void {
    const default_midi_channel = [_]u4{channel.midi_channel};
    const allowed_channels = channel.config.midi_channels orelse default_midi_channel[0..];

    for (midi_events) |midi_event| {
        if (midi_event.program() != null) continue;

        const event_channel = midi_event.channel() orelse continue;

        if (std.mem.indexOfScalar(u4, allowed_channels, event_channel) == null) continue;

        std.debug.print("MidiMessage: {f}\n", .{midi_event});
        channel.plugin.midi_sequence.addEvent(0, midi_event.data[0..]) catch |err| {
            std.debug.print(
                "Dropping MIDI event for channel {d}: {s}\n",
                .{ @as(u8, event_channel), @errorName(err) },
            );
            continue;
        };

        last_midi_event_ms.store(std.Io.Clock.awake.now(io).toMilliseconds(), .seq_cst);
    }
}

fn mixFrames(out: []f32, frame_count: usize, channels: []const Channel, patch_volume: f32) void {
    std.debug.assert(out.len == frame_count * 2);
    @memset(out, 0);

    for (channels) |channel| {
        const plugin = channel.plugin;
        std.debug.assert(plugin.audio_ports.items.len == 1 or plugin.audio_ports.items.len == 2);

        const left_buffer = plugin.audio_out_bufs[plugin.audio_ports.items[0]] orelse unreachable;
        const right_port = if (plugin.audio_ports.items.len == 1) plugin.audio_ports.items[0] else plugin.audio_ports.items[1];
        const right_buffer = plugin.audio_out_bufs[right_port] orelse unreachable;

        const gain = channel.config.volume * patch_volume;

        for (0..frame_count) |frame_index| {
            const sample_index = frame_index * 2;
            out[sample_index] += left_buffer[frame_index] * gain;
            out[sample_index + 1] += right_buffer[frame_index] * gain;
        }
    }
}

fn pollProgramChange(
    current_program: *u7,
    patch_set: *const patch_mod.PatchSet,
) bool {
    const new_midi_program_local: u7 = @intCast(new_midi_program.load(.seq_cst));
    if (new_midi_program_local == current_program.*) return false;

    std.debug.print("Program change {}\n", .{new_midi_program_local});

    if (patch_set.has_midi_program(new_midi_program_local)) {
        current_program.* = new_midi_program_local;
        return true;
    }

    std.debug.print(
        "Program ignored because not available in patch set {any}\n",
        .{patch_set.patches},
    );
    new_midi_program.store(current_program.*, .seq_cst);
    return false;
}

fn saveChannelStates(
    allocator: std.mem.Allocator,
    channels: []const Channel,
    patch_path: []const u8,
) !void {
    for (channels) |channel| {
        const plugin_patch_file_name = try patch_mod.get_plugin_patch_file_name(
            allocator,
            patch_path,
            channel.midi_channel,
        );
        defer allocator.free(plugin_patch_file_name);
        try channel.plugin.saveState(plugin_patch_file_name);
    }
}

test "mixFrames duplicates mono output and preserves stereo with channel and patch gain" {
    var left = [_]f32{ 1, -0.5 };
    var right = [_]f32{ 0.25, -1 };
    var buffers = [_]?[]f32{ &left, &right };
    var mono_ports = [_]usize{0};
    var stereo_ports = [_]usize{ 0, 1 };
    var plugin: SynthPlugin = undefined;
    plugin.audio_out_bufs = &buffers;
    plugin.audio_ports = std.ArrayList(usize).fromOwnedSlice(&mono_ports);
    var config = patch_mod.ChannelConfig{ .volume = 0.5, .plugins = &.{} };
    const channels = [_]Channel{.{ .midi_channel = 0, .config = &config, .plugin = &plugin }};
    var output: [4]f32 = undefined;
    mixFrames(&output, 2, &channels, 0.5);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.25, -0.125, -0.125 }, &output);
    plugin.audio_ports = std.ArrayList(usize).fromOwnedSlice(&stereo_ports);
    mixFrames(&output, 2, &channels, 0.5);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, 0.0625, -0.125, -0.25 }, &output);
}

test "exit on UI close waits for the last UI and respects the option" {
    var first: SynthPlugin = undefined;
    first.session = UiSession{};
    var second: SynthPlugin = undefined;
    second.session = UiSession{};
    var headless: SynthPlugin = undefined;
    headless.session = null;
    var config = patch_mod.ChannelConfig{ .plugins = &.{} };
    const channels = [_]Channel{
        .{ .midi_channel = 0, .config = &config, .plugin = &first },
        .{ .midi_channel = 1, .config = &config, .plugin = &second },
        .{ .midi_channel = 2, .config = &config, .plugin = &headless },
    };

    try std.testing.expect(!shouldQuitOnUiClose(true, &channels));
    first.session.?.closed.store(true, .release);
    try std.testing.expect(!shouldQuitOnUiClose(true, &channels));
    second.session.?.closed.store(true, .release);
    try std.testing.expect(shouldQuitOnUiClose(true, &channels));
    try std.testing.expect(!shouldQuitOnUiClose(false, &channels));
    try std.testing.expect(!shouldQuitOnUiClose(true, channels[2..]));
    try std.testing.expect(!shouldQuitOnUiClose(true, &.{}));
}

test "terminal commands consume newlines for repeated saves and quit" {
    var reader = std.Io.Reader.fixed("s\ns\r\n\nq\n");
    for ([_][]const u8{ "s", "s", "", "q" }) |expected| {
        try std.testing.expectEqualStrings(expected, (try readCommand(&reader)).?);
    }
    try std.testing.expect(try readCommand(&reader) == null);
}
