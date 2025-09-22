const std = @import("std");

const c = @cImport({
    @cInclude("lilv-0/lilv/lilv.h");
});

pub fn convertUritoPath(allocator: std.mem.Allocator, uri: [*c]const u8) ![:0]u8 {
    const path_encoded = c.lilv_uri_to_path(uri) orelse {
        std.log.err("lilv_uri_to_path failed for {s}", .{std.mem.sliceTo(uri, 0)});
        return error.CanNotConvertUriToPath;
    };
    return decodeUriComponent(allocator, std.mem.sliceTo(path_encoded, 0));
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

test "decodeUriComponent" {
    const allocator = std.testing.allocator;
    const input = "hello%20zig%21";
    const result = try decodeUriComponent(allocator, input);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("hello zig!", result);
}
