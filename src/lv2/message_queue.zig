const std = @import("std");

/// Bounded single-producer/single-consumer queue. Storage is allocated before
/// audio starts; publishing and consuming messages never allocate or lock.
pub const MessageQueue = struct {
    pub const capacity = 16;
    pub const max_message_size = 65536;
    pub const Message = struct {
        port: u32,
        protocol: u32,
        size: u32,
        data: [max_message_size]u8 align(8),

        pub fn bytes(self: *const Message) []const u8 {
            return self.data[0..self.size];
        }
    };

    messages: []Message,
    read_index: std.atomic.Value(usize) = .init(0),
    write_index: std.atomic.Value(usize) = .init(0),

    pub fn init(allocator: std.mem.Allocator) !MessageQueue {
        return .{ .messages = try allocator.alloc(Message, capacity) };
    }

    pub fn deinit(self: *MessageQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.messages);
    }

    pub fn push(self: *MessageQueue, port: u32, protocol: u32, bytes: []const u8) bool {
        if (bytes.len > max_message_size) return false;
        const write = self.write_index.load(.monotonic);
        if (write -% self.read_index.load(.acquire) >= capacity) return false;
        const message = &self.messages[write % capacity];
        message.port = port;
        message.protocol = protocol;
        message.size = @intCast(bytes.len);
        @memcpy(message.data[0..bytes.len], bytes);
        self.write_index.store(write +% 1, .release);
        return true;
    }

    /// The consumer must keep the message until it has finished reading it.
    pub fn peek(self: *MessageQueue) ?*const Message {
        const read = self.read_index.load(.monotonic);
        if (read == self.write_index.load(.acquire)) return null;
        return &self.messages[read % capacity];
    }

    pub fn pop(self: *MessageQueue) void {
        self.read_index.store(self.read_index.load(.monotonic) +% 1, .release);
    }

    pub fn hasMessages(self: *MessageQueue) bool {
        return self.read_index.load(.acquire) != self.write_index.load(.acquire);
    }
};

test "MessageQueue preserves order, rejects overflow, and reuses consumed slots" {
    var queue = try MessageQueue.init(std.testing.allocator);
    defer queue.deinit(std.testing.allocator);
    for (0..MessageQueue.capacity) |i| {
        try std.testing.expect(queue.push(@intCast(i), 7, "lyrics"));
    }
    try std.testing.expect(!queue.push(99, 0, "overflow"));
    for (0..MessageQueue.capacity) |i| {
        const message = queue.peek().?;
        try std.testing.expectEqual(i, message.port);
        try std.testing.expectEqual(7, message.protocol);
        try std.testing.expectEqualStrings("lyrics", message.bytes());
        queue.pop();
    }
    try std.testing.expect(queue.peek() == null);
    try std.testing.expect(queue.push(3, 8, "next"));
    try std.testing.expectEqualStrings("next", queue.peek().?.bytes());
}
