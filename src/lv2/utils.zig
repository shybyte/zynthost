const std = @import("std");
const utils = @import("../utils.zig");

const c = @cImport({
    @cInclude("lilv-0/lilv/lilv.h");
});

pub fn convertUriToPath(allocator: std.mem.Allocator, uri: [*c]const u8) ![:0]u8 {
    const path_encoded = c.lilv_uri_to_path(uri) orelse {
        std.log.err("lilv_uri_to_path failed for {s}", .{std.mem.sliceTo(uri, 0)});
        return error.CanNotConvertUriToPath;
    };
    return utils.decodeUriComponent(allocator, std.mem.sliceTo(path_encoded, 0));
}
