const std = @import("std");

const synth_plugin_mod = @import("lv2/synth_plugin.zig");
const SynthPlugin = synth_plugin_mod.SynthPlugin;
const MidiInput = @import("./midi_input.zig").MidiInput;
const audio_output = @import("./audio_output.zig");
const patch_mod = @import("./patch.zig");

const freq = 440.0; // A4 note
const sample_rate = 44100;
const volume: f32 = 0.1; // Set desired output volume (0.0 to 1.0)

const State = struct { phase: f64 = 0.0, synth_plugins: []*SynthPlugin, midi_input: *MidiInput };

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

    for (data.synth_plugins, 0..) |synth_plugin, channel| {
        for (midi_events) |midi_event| {
            if (midi_event.channel() == channel) {
                std.debug.print("MidiMessage: {f}\n", .{midi_event});
                synth_plugin.midi_sequence.addEvent(0, &midi_event.data);
            }
        }

        synth_plugin.run(@intCast(frameCount));
    }

    for (0..frameCount) |i| {
        var value_sum: f32 = 0.0;

        for (data.synth_plugins) |synth_plugin| {
            var value_sum_synth: f32 = 0.0;
            for (synth_plugin.audio_ports.items) |audio_port_index| {
                value_sum_synth += synth_plugin.audio_out_bufs[audio_port_index].?[i];
            }
            value_sum += value_sum_synth / @as(f32, @floatFromInt(synth_plugin.audio_ports.items.len)) * 0.5;
        }

        out[i] = value_sum / @as(f32, @floatFromInt(data.synth_plugins.len));
    }

    return audio_output.paContinue;
}

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

    const patch_file_name = if (args.len == 2) args[1] else return error.MissingFileName;

    std.debug.print("Load patch {s} ...", .{patch_file_name});
    const patch = try patch_mod.loadPatch(allocator, patch_file_name);
    defer patch.deinit();
    std.debug.print(" successfully.", .{});

    const world = try synth_plugin_mod.create_world(allocator);
    defer synth_plugin_mod.free_world();

    var plugins = try allocator.alloc(*SynthPlugin, patch.value.channels.len);
    for (patch.value.channels, 0..) |channel, i| {
        const plugin = try SynthPlugin.init(allocator, world, channel.plugins[0].uri);

        const plugin_patch_file_name = try patch_mod.get_plugin_patch_file_name(allocator, patch_file_name, @intCast(i));
        defer allocator.free(plugin_patch_file_name);
        plugin.loadState(plugin_patch_file_name) catch |err| {
            std.debug.print("Failed to load plugin patch {}\n", .{err});
        };

        plugins[i] = plugin;
    }
    defer allocator.free(plugins);
    defer {
        for (plugins) |plugin| {
            plugin.deinit();
        }
    }

    var midi_input = try MidiInput.init(std.heap.page_allocator);
    defer midi_input.deinit();

    var state = State{
        .synth_plugins = plugins,
        .midi_input = &midi_input,
    };

    try audio_output.startAudio(&state, audioCallback);
    defer audio_output.stopAudio();

    for (plugins) |plugin| {
        _ = try plugin.showUI();
    }

    // while (!plugins[0].session.isClosed()) {
    //     std.Thread.sleep(100 * std.time.ns_per_ms);
    // }

    var stdin_file = std.fs.File.stdin();
    var read_buffer: [1024]u8 = undefined;
    var reader = stdin_file.reader(&read_buffer);

    while (true) {
        const line = try reader.interface.takeDelimiterExclusive('\n');
        if (line.len == 0) break; // EOF

        const trimmed = std.mem.trimRight(u8, line, "\r\n");

        if (std.mem.eql(u8, trimmed, "s")) {
            std.debug.print("Saving ... \n", .{});
            for (plugins, 0..) |plugin, channel| {
                const plugin_patch_file_name = try patch_mod.get_plugin_patch_file_name(allocator, patch_file_name, @intCast(channel));
                defer allocator.free(plugin_patch_file_name);
                try plugin.saveState(plugin_patch_file_name);
            }
        }

        if (std.mem.eql(u8, trimmed, "q")) break;

        std.debug.print("You entered: \"{s}\"\n", .{trimmed});
    }

    for (plugins) |plugin| {
        plugin.session.deinit();
    }

    // try synth_plugin.saveState();

    std.debug.print("Finished.\n", .{});
}
