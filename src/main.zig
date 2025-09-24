const std = @import("std");

const synth_plugin_mod = @import("lv2/synth_plugin.zig");
const SynthPlugin = synth_plugin_mod.SynthPlugin;
const MidiInput = @import("./midi_input.zig").MidiInput;
const audio_output = @import("./audio_output.zig");

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

    for (data.synth_plugins) |synth_plugin| {
        for (midi_events) |midi_event| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, midi_event, .little);
            std.debug.print("MidiMessage: {any}\n", .{buf[0..3]});
            synth_plugin.midi_sequence.addEvent(0, buf[0..3]);
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

    const world = try synth_plugin_mod.create_world(allocator);
    defer synth_plugin_mod.free_world();

    // const synths = [_][:0]const u8{ "http://tytel.org/helm", "https://surge-synthesizer.github.io/lv2/surge-xt" };
    const synths = [_][:0]const u8{"http://tytel.org/helm"};
    // const synths = [_][:0]const u8{"https://surge-synthesizer.github.io/lv2/surge-xt"};

    var plugins = try allocator.alloc(*SynthPlugin, synths.len);
    defer allocator.free(plugins);

    for (synths, plugins) |synth, *slot| {
        slot.* = try SynthPlugin.init(allocator, world, synth);
    }

    defer {
        for (plugins) |plugin| {
            plugin.deinit();
        }
    }

    // const plugin_patch_filename = "patches/plugin_patch.json";
    // synth_plugin.loadState("/tmp", "test.ttl") catch |err| {
    //     std.debug.print("Failed to load plugin patch {}\n", .{err});
    // };

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

    while (!plugins[0].session.isClosed()) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    for (plugins) |plugin| {
        plugin.session.deinit();
    }

    // try synth_plugin.saveState();

    std.debug.print("Finished.\n", .{});
}
