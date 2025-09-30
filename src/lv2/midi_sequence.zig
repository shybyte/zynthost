const std = @import("std");

const c = @cImport({
    @cInclude("lv2/atom/atom.h");
    @cInclude("lv2/midi/midi.h");
    @cInclude("lv2/time/time.h");
});

pub const MidiSequence = struct {
    allocator: std.mem.Allocator,
    buf: []align(@alignOf(c.LV2_Atom_Sequence)) u8,
    atom_sequence_urid: u32,
    midi_event_urid: u32,
    time_frames_urid: u32,

    pub fn init(
        allocator: std.mem.Allocator,
        capacity: usize,
        atom_sequence_urid: u32,
        midi_event_urid: u32,
        time_frames_urid: u32,
    ) !MidiSequence {
        const buf = try allocator.alignedAlloc(u8, std.mem.Alignment.of(c.LV2_Atom_Sequence), capacity);
        errdefer allocator.free(buf);

        var self = MidiSequence{
            .allocator = allocator,
            .buf = buf,
            .atom_sequence_urid = atom_sequence_urid,
            .midi_event_urid = midi_event_urid,
            .time_frames_urid = time_frames_urid,
        };
        self.clear();
        return self;
    }

    pub fn deinit(self: *MidiSequence) void {
        self.allocator.free(self.buf);
    }

    pub fn seq(self: *MidiSequence) *c.LV2_Atom_Sequence {
        return @ptrCast(@alignCast(self.buf.ptr));
    }

    pub fn clear(self: *MidiSequence) void {
        std.debug.assert(self.buf.len >= @sizeOf(c.LV2_Atom) + @sizeOf(c.LV2_Atom_Sequence_Body));
        @memset(self.buf, 0);

        const seq_ptr: *c.LV2_Atom_Sequence = @ptrCast(@alignCast(self.buf.ptr));
        seq_ptr.atom.type = self.atom_sequence_urid;
        seq_ptr.atom.size = @intCast(@sizeOf(c.LV2_Atom_Sequence_Body));

        const body_ptr: *c.LV2_Atom_Sequence_Body =
            @ptrCast(@alignCast(self.buf.ptr + @sizeOf(c.LV2_Atom)));
        body_ptr.unit = self.time_frames_urid; // URID of time:frames
        body_ptr.pad = 0;
    }

    pub fn addEvent(self: *MidiSequence, time_frames: i64, data: []const u8) Error!void {
        if (data.len == 0 or data.len > std.math.maxInt(u32)) {
            return Error.InvalidMidiSize;
        }

        const event_body_size: u32 = @intCast(data.len);

        const seq_ptr = self.seq();
        const total_len = self.buf.len;

        const body_size: usize = @intCast(seq_ptr.atom.size);
        const write_off = @sizeOf(c.LV2_Atom) + body_size;

        const EventHeader = extern struct {
            time: i64, // frames
            body_size: u32,
            body_type: u32,
        };

        const header_sz = @sizeOf(EventHeader);
        const unaligned = header_sz + data.len;
        const aligned = roundUp8(unaligned);
        if (write_off + aligned > total_len) {
            return Error.NoSpace;
        }

        var p: [*]u8 = self.buf.ptr + write_off;

        var eh = EventHeader{
            .time = time_frames,
            .body_size = event_body_size,
            .body_type = self.midi_event_urid,
        };
        @memcpy(p[0..header_sz], std.mem.asBytes(&eh));
        p += header_sz;

        @memcpy(p[0..data.len], data);
        p += data.len;

        const pad = aligned - unaligned;
        if (pad > 0) @memset(p[0..pad], 0);

        const new_body_size = body_size + aligned;
        if (new_body_size > std.math.maxInt(u32)) {
            return Error.NoSpace;
        }

        seq_ptr.atom.size = @intCast(new_body_size);
    }

    fn roundUp8(n: usize) usize {
        const r = n & 7;
        return if (r == 0) n else n + (8 - r);
    }

    pub const Error = error{
        NoSpace,
        InvalidMidiSize,
    };
};

test "MidiSequence frames" {
    var ms = try MidiSequence.init(std.testing.allocator, 1024, 1, 2, 3);
    defer ms.deinit();
    try ms.addEvent(128, &[_]u8{ 0x90, 60, 100 });
    try ms.addEvent(512, &[_]u8{ 0x80, 60, 64 });
    ms.clear();
    const seq_ptr = ms.seq();
    try std.testing.expect(@as(usize, @intCast(seq_ptr.atom.size)) == @sizeOf(c.LV2_Atom_Sequence_Body));
}

test "MidiSequence adds two MIDI events with correct layout" {
    // URIDs (just sample values for the test)
    const URID_SEQUENCE: u32 = 1;
    const URID_MIDI_EVENT: u32 = 2;
    const URID_TIME_FRAMES: u32 = 3;

    // Each event occupies: header(16) + data(3) -> 19, rounded up to 24 bytes.
    // Total buffer needed: LV2_Atom(8) + Sequence_Body(8) + 2 * 24 = 64 bytes.
    var seq = try MidiSequence.init(std.testing.allocator, 64, URID_SEQUENCE, URID_MIDI_EVENT, URID_TIME_FRAMES);
    defer seq.deinit();

    // Two MIDI messages: Note On (ch 1, note 60, vel 100) at t=0,
    // then Note Off (ch 1, note 60, vel 0) at t=480 frames.
    const ev1 = [_]u8{ 0x90, 60, 100 };
    const ev2 = [_]u8{ 0x80, 60, 0 };

    try seq.addEvent(0, &ev1);
    try seq.addEvent(480, &ev2);

    const seq_ptr: *c.LV2_Atom_Sequence = seq.seq();

    // Verify top-level atom header and body header.
    try std.testing.expectEqual(@as(u32, URID_SEQUENCE), seq_ptr.atom.type);
    // After two events, atom.size = body(8) + 24 + 24 = 56
    try std.testing.expectEqual(@as(u32, 56), seq_ptr.atom.size);

    const body_ptr: *c.LV2_Atom_Sequence_Body =
        @ptrCast(@alignCast(@as([*]u8, @ptrCast(seq.buf.ptr)) + @sizeOf(c.LV2_Atom)));
    try std.testing.expectEqual(@as(u32, URID_TIME_FRAMES), body_ptr.unit);
    try std.testing.expectEqual(@as(u32, 0), body_ptr.pad);

    // Define the event header used by MidiSequence.addEvent for inspection.
    const EventHeader = extern struct {
        time: i64,
        body_size: u32,
        body_type: u32,
    };

    const header_sz = @sizeOf(EventHeader);
    const event_stride = 24; // 16 header + 3 data + 5 pad -> rounded to 8

    // Offsets to the two events within the buffer
    const base_off = @sizeOf(c.LV2_Atom) + @sizeOf(c.LV2_Atom_Sequence_Body); // 8 + 8 = 16
    const ev1_off = base_off; // 16
    const ev2_off = base_off + event_stride; // 40

    // ---- Check Event 1 ----
    const ev1_hdr_ptr: *const EventHeader =
        @ptrCast(@alignCast(seq.buf.ptr + ev1_off));
    try std.testing.expectEqual(@as(i64, 0), ev1_hdr_ptr.time);
    try std.testing.expectEqual(@as(u32, ev1.len), ev1_hdr_ptr.body_size);
    try std.testing.expectEqual(@as(u32, URID_MIDI_EVENT), ev1_hdr_ptr.body_type);

    const ev1_data = seq.buf[(ev1_off + header_sz)..(ev1_off + header_sz + ev1.len)];
    try std.testing.expect(std.mem.eql(u8, ev1_data, &ev1));

    // Padding after event 1 should be 5 zeros to reach 24 bytes total.
    const ev1_pad = seq.buf[(ev1_off + header_sz + ev1.len)..(ev1_off + event_stride)];
    for (ev1_pad) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // ---- Check Event 2 ----
    const ev2_hdr_ptr: *const EventHeader =
        @ptrCast(@alignCast(seq.buf.ptr + ev2_off));
    try std.testing.expectEqual(@as(i64, 480), ev2_hdr_ptr.time);
    try std.testing.expectEqual(@as(u32, ev2.len), ev2_hdr_ptr.body_size);
    try std.testing.expectEqual(@as(u32, URID_MIDI_EVENT), ev2_hdr_ptr.body_type);

    const ev2_data = seq.buf[(ev2_off + header_sz)..(ev2_off + header_sz + ev2.len)];
    try std.testing.expect(std.mem.eql(u8, ev2_data, &ev2));

    // Padding after event 2 should also be zeros.
    const ev2_pad = seq.buf[(ev2_off + header_sz + ev2.len)..(ev2_off + event_stride)];
    for (ev2_pad) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // Finally, verify the total bytes used equals the buffer end for this case:
    // LV2_Atom (8) + atom.size (56) = 64.
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(c.LV2_Atom) + @as(usize, seq_ptr.atom.size));
}

test "MidiSequence accepts variable-sized MIDI messages" {
    const URID_SEQUENCE: u32 = 1;
    const URID_MIDI_EVENT: u32 = 2;
    const URID_TIME_FRAMES: u32 = 3;

    var seq = try MidiSequence.init(std.testing.allocator, 64, URID_SEQUENCE, URID_MIDI_EVENT, URID_TIME_FRAMES);
    defer seq.deinit();

    try seq.addEvent(0, &[_]u8{0xF8});
    try seq.addEvent(240, &[_]u8{ 0xC0, 42 });

    const seq_ptr: *c.LV2_Atom_Sequence = seq.seq();
    try std.testing.expectEqual(@as(u32, 56), seq_ptr.atom.size);
}

test "MidiSequence rejects empty MIDI messages" {
    const URID_SEQUENCE: u32 = 1;
    const URID_MIDI_EVENT: u32 = 2;
    const URID_TIME_FRAMES: u32 = 3;

    var seq = try MidiSequence.init(std.testing.allocator, 64, URID_SEQUENCE, URID_MIDI_EVENT, URID_TIME_FRAMES);
    defer seq.deinit();

    try std.testing.expectError(MidiSequence.Error.InvalidMidiSize, seq.addEvent(0, &[_]u8{}));
}

test "MidiSequence signals NoSpace when buffer is full" {
    const URID_SEQUENCE: u32 = 1;
    const URID_MIDI_EVENT: u32 = 2;
    const URID_TIME_FRAMES: u32 = 3;

    var seq = try MidiSequence.init(std.testing.allocator, 40, URID_SEQUENCE, URID_MIDI_EVENT, URID_TIME_FRAMES);
    defer seq.deinit();

    try seq.addEvent(0, &[_]u8{ 0x90, 60, 100 });
    try std.testing.expectError(MidiSequence.Error.NoSpace, seq.addEvent(120, &[_]u8{ 0x80, 60, 0 }));
}
