const std = @import("std");

const pa = @cImport({
    @cInclude("portaudio.h");
});

pub const AudioCallback = pa.PaStreamCallback;
pub const PaStreamCallbackTimeInfo = pa.PaStreamCallbackTimeInfo;
pub const PaStreamCallbackFlags = pa.PaStreamCallbackFlags;
pub const paContinue = pa.paContinue;

const sample_rate = 48000;

var stream: ?*pa.PaStream = null;

pub fn startAudio(user_data: ?*anyopaque, audioCallback: AudioCallback) !void {
    const err = pa.Pa_Initialize();
    if (err != pa.paNoError) return errorFromPa(err);

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
                        user_data,
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
            user_data,
        );

        if (openErr != pa.paNoError) return errorFromPa(openErr);
    }

    _ = pa.Pa_StartStream(stream);
}

pub fn stopAudio() void {
    _ = pa.Pa_StopStream(stream);
    _ = pa.Pa_CloseStream(stream);
    _ = pa.Pa_Terminate();
}

fn errorFromPa(code: pa.PaError) !void {
    const msg = pa.Pa_GetErrorText(code);
    std.debug.print("PortAudio error: {s}\n", .{msg});
    return error.PortAudioFailed;
}
