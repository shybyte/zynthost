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

const State = struct { phase: f64 = 0.0, synth_plugin: *SynthPlugin, midi_input: *MidiInput };

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

    const midi_events = data.midi_input.poll();
    for (midi_events) |midi_event| {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, midi_event, .little);
        std.debug.print("MidiMessage: {any}\n", .{buf[0..3]});
        data.synth_plugin.midi_sequence.addEvent(0, buf[0..3]);
    }

    data.synth_plugin.run(@intCast(frameCount));

    for (0..frameCount) |i| {
        var value_sum: f32 = 0.0;

        for (data.synth_plugin.audio_ports.items) |audio_port_index| {
            value_sum += data.synth_plugin.audio_out_bufs[audio_port_index].?[i];
        }

        out[i] = value_sum / @as(f32, @floatFromInt(data.synth_plugin.audio_ports.items.len)) * 0.5;
    }

    return pa.paContinue;
}

fn playSound(synth_plugin: *SynthPlugin) !void {
    var midi_input = try MidiInput.init(std.heap.page_allocator);
    defer midi_input.deinit();

    var state = State{
        .synth_plugin = synth_plugin,
        .midi_input = &midi_input,
    };

    const err = pa.Pa_Initialize();
    if (err != pa.paNoError) return errorFromPa(err);
    defer _ = pa.Pa_Terminate();

    const count = pa.Pa_GetHostApiCount();
    if (count < 0) {
        std.debug.print("Error getting host API count\n", .{});
        return;
    }

    std.debug.print("Available Host APIs:\n", .{});
    var jack_host_index: c_int = 0;
    for (0..@intCast(count)) |i| {
        const info = pa.Pa_GetHostApiInfo(@intCast(i));
        if (info == null) continue;

        std.debug.print("  [{d}] {s}\n", .{ i, std.mem.span((info.*).name) });

        if (std.mem.eql(u8, std.mem.span((info.*).name), "JACK Audio Connection Kit")) {
            jack_host_index = @intCast(i);
            break;
        }
    }

    std.debug.print("jack_host_index = {}\n", .{jack_host_index});

    var stream: ?*pa.PaStream = null;

    // Try JACK first if we found it
    if (jack_host_index >= 0) {
        const host_info = pa.Pa_GetHostApiInfo(jack_host_index);
        if (host_info != null) {
            const jack_default_dev = (host_info.*).defaultOutputDevice;
            if (jack_default_dev != pa.paNoDevice) {
                const dev_info = pa.Pa_GetDeviceInfo(jack_default_dev);

                std.debug.print("dev_info.*.defaultSampleRate {}\n", .{dev_info.*.defaultSampleRate});

                if (dev_info != null) {
                    var out_params = pa.PaStreamParameters{
                        .device = jack_default_dev,
                        .channelCount = 1, // mono
                        .sampleFormat = pa.paFloat32,
                        .suggestedLatency = (dev_info.*).defaultLowOutputLatency,
                        .hostApiSpecificStreamInfo = null,
                    };

                    const open_err = pa.Pa_OpenStream(
                        &stream,
                        null, // no input
                        &out_params,
                        dev_info.*.defaultSampleRate,
                        pa.paFramesPerBufferUnspecified,
                        pa.paNoFlag,
                        audioCallback,
                        &state,
                    );

                    if (open_err == pa.paNoError) {
                        std.debug.print(
                            "Opened JACK output on device [{d}] {s}\n",
                            .{ jack_default_dev, std.mem.span((dev_info.*).name) },
                        );
                    } else {
                        errorFromPa(open_err) catch {};
                        std.debug.print(
                            "Failed to open JACK stream ({d}). Falling back to default host/device.\n",
                            .{open_err},
                        );
                    }
                }
            } else {
                std.debug.print("JACK found but has no default output device. Falling back.\n", .{});
            }
        }
    }

    // Fallback: open the system default stream if JACK path didn’t set `stream`
    if (stream == null) {
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
    }

    defer _ = pa.Pa_CloseStream(stream);

    _ = pa.Pa_StartStream(stream);
    defer _ = pa.Pa_StopStream(stream);

    try synth_plugin.showUI();
    // std.Thread.sleep(2 * std.time.ns_per_s);

}

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us!\n", .{"codebase"});

    const allocator = std.heap.page_allocator;

    const world = create_world();
    // defer c.lilv_world_free(world.?);

    // c.lilv_world_load_all(world.?);

    // var synth_plugin = try SynthPlugin.init(allocator, world.?, "https://surge-synthesizer.github.io/lv2/surge-xt");
    var synth_plugin = try SynthPlugin.init(allocator, world.?, "http://tytel.org/helm");
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
