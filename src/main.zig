//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const pa = @cImport({
    @cInclude("portaudio.h");
});

const synth_plugin_mod = @import("synth_plugin.zig");
const SynthPlugin = synth_plugin_mod.SynthPlugin;
const create_world = @import("synth_plugin.zig").create_world;
const MidiInput = @import("./midi_input.zig").MidiInput;

const freq = 440.0; // A4 note
const sample_rate = 44100;
const volume: f32 = 0.1; // Set desired output volume (0.0 to 1.0)
const NumSeconds = 2;

const State = struct {
    phase: f64 = 0.0,
    synth_plugin: *SynthPlugin,
};

fn audioCallback(
    input: ?*const anyopaque,
    output: ?*anyopaque,
    frameCount: c_ulong,
    timeInfo: [*c]const pa.PaStreamCallbackTimeInfo,
    statusFlags: pa.PaStreamCallbackFlags,
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

    data.synth_plugin.run(@intCast(frameCount));

    for (0..frameCount) |i| {
        const v = data.synth_plugin.audio_out_bufs[5].?[i];
        // if (v != 0.0) {
        //     std.debug.print(" {}\n", .{v});
        // }
        out[i] = v * 0.5;
    }

    // const increment = 2.0 * std.math.pi * freq / @as(f32, sample_rate);
    // var i: u32 = 0;
    // // std.debug.print("framecount {}\n", .{frameCount});
    // while (i < frameCount) : (i += 1) {
    //     out[i] = volume * @as(f32, @floatCast(std.math.sin(data.phase)));

    //     data.phase += increment;
    //     if (data.phase >= 2.0 * std.math.pi) {
    //         data.phase -= 2.0 * std.math.pi;
    //     }
    // }

    return pa.paContinue;
}

fn playSound(synth_plugin: *SynthPlugin) !void {
    var state = State{ .synth_plugin = synth_plugin };
    const err = pa.Pa_Initialize();
    if (err != pa.paNoError) return errorFromPa(err);
    defer _ = pa.Pa_Terminate();

    const count = pa.Pa_GetHostApiCount();
    if (count < 0) {
        std.debug.print("Error getting host API count\n", .{});
        return;
    }

    std.debug.print("Available Host APIs:\n", .{});
    var jackHostIndex: c_int = 0;
    for (0..@intCast(count)) |i| {
        const info = pa.Pa_GetHostApiInfo(@intCast(i));
        if (info == null) continue;

        std.debug.print("  [{d}] {s}\n", .{ i, std.mem.span((info.*).name) });

        if (std.mem.eql(u8, std.mem.span((info.*).name), "JACK Audio Connection Kit")) {
            jackHostIndex = @intCast(i);
            break;
        }
    }

    var stream: ?*pa.PaStream = null;

    const openErr = pa.Pa_OpenDefaultStream(
        &stream,
        0, // no input
        1, // mono output
        pa.paFloat32,
        sample_rate,
        pa.paFramesPerBufferUnspecified,
        audioCallback,
        &state,
    );

    if (openErr != pa.paNoError) return errorFromPa(openErr);
    defer _ = pa.Pa_CloseStream(stream);

    _ = pa.Pa_StartStream(stream);

    try synth_plugin.showUI();

    var midi_input = try MidiInput.init(std.heap.page_allocator);
    defer midi_input.deinit();

    for (0..100) |_| {
        const midi_events = midi_input.poll();
        for (midi_events) |midi_event| {
            var buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &buf, midi_event, .little); // or .little
            std.debug.print("MidiMessage: {any}\n", .{buf[0..3]});
            try synth_plugin.midi_sequence.addEvent(0, buf[0..3]);
        }

        std.Thread.sleep(40 * std.time.ns_per_ms);
    }

    // std.Thread.sleep(NumSeconds * std.time.ns_per_s);
    _ = pa.Pa_StopStream(stream);
}

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us!\n", .{"codebase"});

    const allocator = std.heap.page_allocator;

    const world = create_world();
    // defer c.lilv_world_free(world.?);

    // c.lilv_world_load_all(world.?);

    var synth_plugin = try SynthPlugin.init(allocator, world.?, "https://surge-synthesizer.github.io/lv2/surge-xt");
    defer synth_plugin.deinit();

    // try synth_plugin.showUI();
    try playSound(synth_plugin);
    // std.debug.print(" {any}\n", .{synth_plugin.audio_out_bufs[5]});

    // var midi_input = try MidiInput.init(allocator);
    // defer midi_input.deinit();

    // for (0..100) |_| {
    //     midi_input.poll();
    //     std.Thread.sleep(100 * std.time.ns_per_ms);
    // }

    std.debug.print("Finished.\n", .{});
}

fn errorFromPa(code: pa.PaError) !void {
    const msg = pa.Pa_GetErrorText(code);
    std.debug.print("PortAudio error: {s}\n", .{msg});
    return error.PortAudioFailed;
}

const std = @import("std");
