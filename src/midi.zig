const std = @import("std");

pub const MidiMessage = struct {
    data: [3]u8,

    pub fn init(status: u8, data1: u8, data2: u8) MidiMessage {
        return MidiMessage{ .data = .{ status, data1, data2 } };
    }

    /// Extract the MIDI channel (0–15) for channel voice messages.
    pub fn channel(self: MidiMessage) ?u4 {
        const status = self.data[0];

        // Channel voice messages are 0x8?–0xE?. Everything else (system/common)
        // has no channel, and data bytes (< 0x80) are not valid status bytes.
        if (status < 0x80 or (status & 0xF0) == 0xF0) {
            return null;
        }

        return @truncate(status & 0x0F);
    }

    /// If this is a Program Change message (0xC0–0xCF), return the program number.
    pub fn program(self: MidiMessage) ?u7 {
        const status_nibble: u8 = self.data[0] >> 4;
        if (status_nibble == 0xC) {
            // Program number is in data1 (7 bits).
            return @truncate(self.data[1]);
        }
        return null;
    }

    /// Custom formatter used by `{f}` if this signature matches exactly.
    pub fn format(
        self: MidiMessage,
        writer: anytype,
    ) !void {
        try writer.print(
            "MidiMessage(status=0x{X:0>2}, data1={d}, data2={d}",
            .{ self.data[0], self.data[1], self.data[2] },
        );

        if (self.channel()) |ch| {
            try writer.print(", channel={d})", .{ch});
        } else {
            try writer.print(", channel=--)", .{});
        }
    }
};

test "midi message" {
    var msg = MidiMessage.init(0x91, 60, 100); // Note On, channel 1, note 60, velocity 100

    try std.testing.expect(msg.data[0] == 0x91);
    try std.testing.expect(msg.data[1] == 60);
    try std.testing.expect(msg.data[2] == 100);
    try std.testing.expectEqual(@as(?u4, 1), msg.channel());
}

test "midi message format" {
    const msg = MidiMessage.init(0x91, 60, 100);

    const gpa = std.testing.allocator;
    const s = try std.fmt.allocPrint(gpa, "{f}", .{msg});
    defer gpa.free(s);

    try std.testing.expectEqualStrings(
        "MidiMessage(status=0x91, data1=60, data2=100, channel=1)",
        s,
    );
}

test "midi message program change" {
    var msg = MidiMessage.init(0xC2, 42, 0); // Program Change, channel 2, program 42

    try std.testing.expectEqual(@as(?u4, 2), msg.channel());
    try std.testing.expectEqual(42, msg.program());

    var note_msg = MidiMessage.init(0x91, 60, 100); // Not a Program Change
    try std.testing.expectEqual(null, note_msg.program());
}

test "midi message system message has no channel" {
    // 0xFA is MIDI Start - a system real-time message without a channel.
    const msg = MidiMessage.init(0xFA, 0, 0);

    try std.testing.expectEqual(@as(?u4, null), msg.channel());

    const gpa = std.testing.allocator;
    const s = try std.fmt.allocPrint(gpa, "{f}", .{msg});
    defer gpa.free(s);

    try std.testing.expectEqualStrings(
        "MidiMessage(status=0xFA, data1=0, data2=0, channel=--)",
        s,
    );
}
