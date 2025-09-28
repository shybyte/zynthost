const std = @import("std");

const synth_plugin_mod = @import("lv2/synth_plugin.zig");
const SynthPlugin = synth_plugin_mod.SynthPlugin;
const MidiInput = @import("./midi_input.zig").MidiInput;
const MidiMessage = @import("./midi.zig").MidiMessage;
const audio_output = @import("./audio_output.zig");
const patch_mod = @import("./patch.zig");
const AppConfig = @import("./config.zig").AppConfig;
const utils = @import("./utils.zig");

const State = struct {
    patch_config: *const patch_mod.PatchConfig,
    channels: []Channel,
    midi_input: *MidiInput,
};

const Channel = struct {
    midi_channel: u7,
    config: *const patch_mod.ChannelConfig,
    plugin: *SynthPlugin,
};

// pseudo "message queue" to get program changes from audioCallback into main
var new_midi_program = std.atomic.Value(u8).init(0);

pub fn main() !void {
    std.debug.print("Starting Zynthost...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) std.debug.print("Memory leaked!\n", .{});
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args); // free what argsAlloc allocated

    const patch_set_path = if (args.len == 2) args[1] else return error.MissingPatchSetFileName;

    std.debug.print("Load patch set {s} ...", .{patch_set_path});
    const patch_set = try patch_mod.PatchSet.load(allocator, patch_set_path);
    defer patch_set.deinit();
    std.debug.print(" successfully.", .{});

    const world = try synth_plugin_mod.create_world(allocator);
    defer synth_plugin_mod.free_world();

    var midi_program = patch_set.value.patches[0].program;
    new_midi_program.store(midi_program, .seq_cst);

    var quit = false;
    while (!quit) {
        const patch = try patch_set.value.loadPatch(allocator, midi_program);
        defer patch.deinit();

        var channels = try std.ArrayList(Channel).initCapacity(allocator, patch.channels().len);
        defer channels.deinit(allocator);
        for (patch.channels(), 0..) |*channel, i| {
            if (channel.plugins.len == 0) continue;
            const plugin = try SynthPlugin.init(allocator, world, channel.plugins[0].uri);

            const plugin_patch_file_name = try patch_mod.get_plugin_patch_file_name(allocator, patch.path, @intCast(i));
            defer allocator.free(plugin_patch_file_name);
            plugin.loadState(plugin_patch_file_name) catch |err| {
                std.debug.print("Failed to load plugin patch {}\n", .{err});
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

        const app_config = try AppConfig.loadWithFallback(allocator);
        defer app_config.deinit();

        var midi_input = try MidiInput.init(std.heap.page_allocator, app_config.value.midi_name_filter);
        defer midi_input.deinit();

        var state = State{
            .patch_config = &patch.config.value,
            .channels = channels.items,
            .midi_input = &midi_input,
        };

        try audio_output.startAudio(&state, audioCallback);
        defer audio_output.stopAudio();

        for (channels.items) |channel| {
            _ = try channel.plugin.showUI();
        }

        var stdin_file = std.fs.File.stdin();
        var read_buffer: [1024]u8 = undefined;
        var reader = stdin_file.reader(&read_buffer);

        while (true) {
            if (pollProgramChange(&midi_program, &patch_set.value)) break;

            if (!try utils.fileHasInput(stdin_file)) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }

            const line = try reader.interface.takeDelimiterExclusive('\n');
            const command = std.mem.trimRight(u8, line, "\r\n");
            std.debug.print("You entered: \"{s}\"\n", .{command});

            if (std.mem.eql(u8, command, "s")) {
                std.debug.print("Saving ... \n", .{});
                try saveChannelStates(allocator, channels.items, patch.path);
            } else if (std.mem.eql(u8, command, "q")) {
                quit = true;
                break;
            }
        }

        for (channels.items) |channel| {
            channel.plugin.session.deinit();
        }
    }

    std.debug.print("Finished.\n", .{});
}

fn audioCallback(
    input: ?*const anyopaque,
    output: ?*anyopaque,
    frameCount: c_ulong,
    timeInfo: [*c]const audio_output.PaStreamCallbackTimeInfo,
    statusFlags: audio_output.PaStreamCallbackFlags,
    userData: ?*anyopaque,
) callconv(.c) c_int {
    _ = input;
    _ = timeInfo;
    _ = statusFlags;

    const data: *State = @ptrCast(@alignCast(userData.?));
    const out: [*]f32 = @ptrCast(@alignCast(output));

    if (frameCount > synth_plugin_mod.max_frames) {
        std.debug.print("audioCallback got framecount {}\n", .{frameCount});
    }

    const midi_events = data.midi_input.poll();

    for (midi_events) |midi_event| {
        if (midi_event.program()) |program| {
            new_midi_program.store(program, .seq_cst);
        }
    }

    for (data.channels) |*channel| {
        routeMidiEvents(channel, midi_events);
        channel.plugin.run(@intCast(frameCount));
    }

    const frame_count: usize = @intCast(frameCount);
    mixFrames(out[0..frame_count], data.channels, data.patch_config.volume);

    return audio_output.paContinue;
}

fn routeMidiEvents(channel: *Channel, midi_events: []const MidiMessage) void {
    for (midi_events) |midi_event| {
        if (midi_event.program() == null and midi_event.channel() == channel.midi_channel) {
            std.debug.print("MidiMessage: {f}\n", .{midi_event});
            channel.plugin.midi_sequence.addEvent(0, &midi_event.data);
        }
    }
}

fn mixFrames(out: []f32, channels: []const Channel, patch_volume: f32) void {
    if (channels.len == 0) {
        @memset(out, 0);
        return;
    }

    const channel_scale = patch_volume / @as(f32, @floatFromInt(channels.len));

    for (out, 0..) |*sample, frame_index| {
        var frame_mix: f32 = 0.0;
        for (channels) |*channel| {
            frame_mix += mixChannelFrame(channel, frame_index);
        }
        sample.* = frame_mix * channel_scale;
    }
}

fn mixChannelFrame(channel: *const Channel, frame_index: usize) f32 {
    const synth_plugin = channel.plugin;
    const port_count = synth_plugin.audio_ports.items.len;
    std.debug.assert(port_count > 0);

    var sample_sum: f32 = 0.0;
    for (synth_plugin.audio_ports.items) |audio_port_index| {
        sample_sum += synth_plugin.audio_out_bufs[audio_port_index].?[frame_index];
    }

    const port_average = sample_sum / @as(f32, @floatFromInt(port_count));
    return port_average * channel.config.volume;
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
            @intCast(channel.midi_channel),
        );
        defer allocator.free(plugin_patch_file_name);
        try channel.plugin.saveState(plugin_patch_file_name);
    }
}
