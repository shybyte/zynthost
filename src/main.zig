const std = @import("std");

const synth_plugin_mod = @import("lv2/synth_plugin.zig");
const SynthPlugin = synth_plugin_mod.SynthPlugin;
const MidiInput = @import("./midi_input.zig").MidiInput;
const audio_output = @import("./audio_output.zig");
const patch_mod = @import("./patch.zig");
const AppConfig = @import("./config.zig").AppConfig;
const utils = @import("./utils.zig");

const freq = 440.0; // A4 note
const sample_rate = 44100;
const volume: f32 = 0.1; // Set desired output volume (0.0 to 1.0)

const State = struct {
    patch_config: *const patch_mod.PatchConfig,
    channels: []Channel,
    midi_input: *MidiInput,
};

// pseudo "message queue" to get program changes from audioCallback into main
var new_midi_program = std.atomic.Value(u8).init(0);

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

    for (
        data.channels,
    ) |channel| {
        for (midi_events) |midi_event| {
            if (midi_event.program() == null and midi_event.channel() == channel.midi_channel) {
                std.debug.print("MidiMessage: {f}\n", .{midi_event});
                channel.plugin.midi_sequence.addEvent(0, &midi_event.data);
            }
        }

        channel.plugin.run(@intCast(frameCount));
    }

    if (data.channels.len > 0) {
        for (0..frameCount) |i| {
            var value_sum: f32 = 0.0;

            for (data.channels) |channel| {
                const synth_plugin = channel.plugin;
                var value_sum_synth: f32 = 0.0;
                for (synth_plugin.audio_ports.items) |audio_port_index| {
                    value_sum_synth += synth_plugin.audio_out_bufs[audio_port_index].?[i] * channel.config.volume;
                }
                value_sum += value_sum_synth / @as(f32, @floatFromInt(synth_plugin.audio_ports.items.len)) * 0.5;
            }

            out[i] = value_sum * data.patch_config.volume / @as(f32, @floatFromInt(data.channels.len));
        }
    } else {
        @memset(out[0..frameCount], 0);
    }

    return audio_output.paContinue;
}

const Channel = struct {
    midi_channel: u7,
    config: *const patch_mod.ChannelConfig,
    plugin: *SynthPlugin,
};

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
        defer channels.deinit(allocator);
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
            const new_midi_program_local: u7 = @intCast(new_midi_program.load(.seq_cst));
            if (new_midi_program_local != midi_program) {
                std.debug.print("Program change {}\n", .{new_midi_program_local});
                if (patch_set.value.has_midi_program(new_midi_program_local)) {
                    midi_program = new_midi_program_local;
                    break;
                } else {
                    std.debug.print("Program ignored because not available in patch set {any}\n", .{patch_set.value.patches});
                    new_midi_program.store(midi_program, .seq_cst);
                }
            }

            if (!try utils.fileHasInput(stdin_file)) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            }

            const line = try reader.interface.takeDelimiterExclusive('\n');
            const trimmed = std.mem.trimRight(u8, line, "\r\n");
            std.debug.print("You entered: \"{s}\"\n", .{trimmed});

            if (std.mem.eql(u8, trimmed, "s")) {
                std.debug.print("Saving ... \n", .{});
                for (channels.items) |channel| {
                    const plugin_patch_file_name = try patch_mod.get_plugin_patch_file_name(allocator, patch.path, @intCast(channel.midi_channel));
                    defer allocator.free(plugin_patch_file_name);
                    try channel.plugin.saveState(plugin_patch_file_name);
                }
            } else if (std.mem.eql(u8, trimmed, "q")) {
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
