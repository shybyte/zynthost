const std = @import("std");

pub fn loadJSON(
    comptime T: type,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(T) {
    const file_content = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(file_content);
    return std.json.parseFromSlice(T, allocator, file_content, .{});
}

pub fn fileHasInput(file: std.fs.File) !bool {
    var fds = [_]std.posix.pollfd{
        .{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    const nready = try std.posix.poll(&fds, 0); // non-blocking check
    if (nready == 0) return false;

    return (fds[0].revents & std.posix.POLL.IN) != 0;
}

/// Decodes a percent-encoded URI component.
/// e.g. "hello%20world" -> "hello world"
pub fn decodeUriComponent(allocator: std.mem.Allocator, input: []const u8) ![:0]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, input.len);
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '%' => {
                if (i + 2 >= input.len) return error.InvalidEncoding;
                const hi = std.fmt.charToDigit(input[i + 1], 16) catch return error.InvalidEncoding;
                const lo = std.fmt.charToDigit(input[i + 2], 16) catch return error.InvalidEncoding;
                out.appendAssumeCapacity(@as(u8, (hi << 4) | lo));
                i += 2;
            },
            // If you want '+' → space behavior (query semantics), uncomment:
            // '+' => try out.append(' '),
            else => out.appendAssumeCapacity(input[i]),
        }
    }

    return out.toOwnedSliceSentinel(allocator, 0); // sized exactly; caller can allocator.free(result)
}

// ============== Tests =================

test "decodeUriComponent" {
    const allocator = std.testing.allocator;
    const input = "hello%20zig%21";
    const result = try decodeUriComponent(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello zig!", result);
}
