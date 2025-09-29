const std = @import("std");
const MidiMessage = @import("./midi.zig").MidiMessage;

// PortMidi C API
const c = @cImport({
    @cInclude("portmidi.h");
});

const StreamRec = struct {
    name: []const u8,
    id: c.PmDeviceID,
    stream: *c.PmStream,
};

pub const MidiInput = struct {
    allocator: std.mem.Allocator,
    streams: std.ArrayList(StreamRec),
    midi_events: std.ArrayList(MidiMessage),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, name_filter_opt: ?[]const u8) !Self {
        if (c.Pm_Initialize() != c.pmNoError) return error.PortMidiInitFailed;
        errdefer _ = c.Pm_Terminate();

        const dev_count = c.Pm_CountDevices();
        if (dev_count <= 0) {
            std.debug.print("No MIDI devices found.\n", .{});
            return error.NoMidiDevicesFound;
        }

        var streams = try std.ArrayList(StreamRec).initCapacity(allocator, 100);
        errdefer {
            for (streams.items) |stream| {
                _ = c.Pm_Close(stream.stream);
            }
            streams.deinit(allocator);
        }

        // Enumerate input devices and open them
        for (0..@intCast(dev_count)) |i| {
            const info = c.Pm_GetDeviceInfo(@intCast(i)) orelse continue;
            if (info.*.input == 0) continue; // Filter for input devices

            const name = std.mem.sliceTo(info.*.name, 0);
            const interf = std.mem.sliceTo(info.*.interf, 0);
            std.debug.print("Input #{d}: {s} ({s})\n", .{ i, name, interf });

            if (name_filter_opt) |name_filter| {
                if (!std.mem.containsAtLeast(u8, name, 1, name_filter)) {
                    continue;
                }
            }

            var stream: *c.PmStream = undefined;
            const err = c.Pm_OpenInput(@ptrCast(&stream), @intCast(i), null, 1024, null, null);
            if (err != c.pmNoError) {
                std.debug.print("  -> open failed: {s}\n", .{std.mem.span(c.Pm_GetErrorText(err))});
                continue;
            }

            // Filter out noisy types
            _ = c.Pm_SetFilter(stream, c.PM_FILT_ACTIVE | c.PM_FILT_SYSEX | c.PM_FILT_CLOCK);

            streams.append(allocator, .{
                .name = name,
                .id = @intCast(i),
                .stream = stream,
            }) catch |append_err| {
                _ = c.Pm_Close(stream);
                return append_err;
            };
        }

        std.debug.print("Listening on {d} input stream(s). Ctrl+C to quit.\n", .{streams.items.len});

        return Self{
            .allocator = allocator,
            .streams = streams,
            .midi_events = try std.ArrayList(MidiMessage).initCapacity(allocator, 100),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.streams.items) |stream| {
            _ = c.Pm_Close(stream.stream);
        }
        self.streams.deinit(self.allocator);

        self.midi_events.deinit(self.allocator);
        defer _ = c.Pm_Terminate();
    }

    pub fn poll(self: *Self) []const MidiMessage {
        self.midi_events.clearRetainingCapacity();

        for (self.streams.items) |s| {
            // Fast poll: returns 1 if data available
            const has = c.Pm_Poll(s.stream);
            if (has == 1) {
                const MaxBatch = 128;
                var evs: [MaxBatch]c.PmEvent = undefined;
                const n = c.Pm_Read(s.stream, &evs, MaxBatch);
                if (n > 0) {
                    const event_count: usize = @intCast(n);
                    self.midi_events.ensureUnusedCapacity(self.allocator, event_count) catch |ensure_err| {
                        std.debug.print(
                            "Dropping {d} MIDI event(s) from {s}: {s}\n",
                            .{ event_count, s.name, @errorName(ensure_err) },
                        );
                        continue;
                    };

                    for (0..event_count) |j| {
                        const e = evs[j];
                        const ts_ms: i64 = @intCast(e.timestamp);
                        const msg: u32 = @bitCast(e.message);

                        print_midi(s.name, ts_ms, msg);
                        // std.debug.print("midi ${x:0>8}\n", .{msg});

                        self.midi_events.appendAssumeCapacity(.{
                            .data = @as([3]u8, @bitCast(@as(u24, @truncate(msg)))),
                        });
                    }
                }
            }
        }

        return self.midi_events.items;
    }
};

fn hi(x: u32, shift: u5) u8 {
    return @intCast((x >> shift) & 0x7F);
}

fn print_midi(device_name: []const u8, ts_ms: i64, msg: u32) void {
    const status: u8 = @intCast(msg & 0xFF);
    const typ: u8 = status & 0xF0;
    const ch: u8 = (status & 0x0F) + 1;
    const d1: u8 = hi(msg, 8);
    const d2: u8 = hi(msg, 16);

    switch (typ) {
        0x90 => { // Note On (vel 0 => off)
            if (d2 == 0)
                std.debug.print("[{d} ms] {s}: NoteOff ch={d} note={d}\n", .{ ts_ms, device_name, ch, d1 })
            else
                std.debug.print("[{d} ms] {s}: NoteOn  ch={d} note={d} vel={d}\n", .{ ts_ms, device_name, ch, d1, d2 });
        },
        0x80 => std.debug.print("[{d} ms] {s}: NoteOff ch={d} note={d}\n", .{ ts_ms, device_name, ch, d1 }),
        0xB0 => std.debug.print("[{d} ms] {s}: CC      ch={d} cc={d} val={d}\n", .{ ts_ms, device_name, ch, d1, d2 }),
        else => {
            // Uncomment to see everything
            // std.debug.print("[{d} ms] {s}: msg=0x{x}\n", .{ ts_ms, device_name, msg });
        },
    }
}

test "MidiInput" {
    const allocator = std.testing.allocator;

    var midi_input = try MidiInput.init(allocator, null);
    defer midi_input.deinit();

    try std.testing.expect(midi_input.streams.items.len >= 0);

    _ = midi_input.poll();

    {
        var midi_input_filtered = try MidiInput.init(allocator, "Eierkuchen");
        defer midi_input_filtered.deinit();

        try std.testing.expect(midi_input_filtered.streams.items.len >= 0);
    }

    {
        if (midi_input.streams.items.len > 0) {
            const midi_device_name = midi_input.streams.items[0].name;
            if (midi_device_name.len >= 3) {
                const name_part = midi_device_name[1 .. midi_device_name.len - 1];
                var midi_input_filtered = try MidiInput.init(allocator, name_part);
                defer midi_input_filtered.deinit();

                try std.testing.expect(midi_input_filtered.streams.items.len <= midi_input.streams.items.len);
            }
        }
    }
}
