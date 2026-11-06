const std = @import("std");
const utils = @import("./utils.zig");

pub const AppConfig = struct {
    midi_name_filter: ?[]u8,

    pub fn loadWithFallback(allocator: std.mem.Allocator, io: std.Io) !std.json.Parsed(AppConfig) {
        return AppConfig.loadWithFallbackAtPath(allocator, io, ".");
    }

    fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
    ) !std.json.Parsed(AppConfig) {
        return utils.loadJSON(AppConfig, allocator, io, path);
    }

    fn loadWithFallbackAtPath(
        allocator: std.mem.Allocator,
        io: std.Io,
        base_path: []const u8,
    ) !std.json.Parsed(AppConfig) {
        const local_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "config.local.json" });
        defer allocator.free(local_path);

        const fallback_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, "config.json" });
        defer allocator.free(fallback_path);

        return AppConfig.load(allocator, io, local_path) catch |err| switch (err) {
            error.FileNotFound => AppConfig.load(allocator, io, fallback_path),
            else => return err,
        };
    }
};

// ============= Tests ===============

test "AppConfig.load" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const parsed_config = try AppConfig.load(allocator, io, "src/_test_data/config.json");
    defer parsed_config.deinit();

    const app_config = parsed_config.value;

    try std.testing.expectEqualDeep("Midi Through Port-0", app_config.midi_name_filter);
}

test "AppConfig.loadWithFallback uses fallback when local missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data = "{ \"midi_name_filter\": \"Fallback Port\" }",
    });

    const base_path = try tmp_dir.parent_dir.realPathFileAlloc(io, &tmp_dir.sub_path, allocator);
    defer allocator.free(base_path);

    const parsed_config = try AppConfig.loadWithFallbackAtPath(allocator, io, base_path);
    defer parsed_config.deinit();

    try std.testing.expect(parsed_config.value.midi_name_filter != null);
    try std.testing.expectEqualStrings("Fallback Port", parsed_config.value.midi_name_filter.?);
}

test "AppConfig.loadWithFallback surfaces invalid local config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "config.json",
        .data = "{ \"midi_name_filter\": null }",
    });
    try tmp_dir.dir.writeFile(io, .{
        .sub_path = "config.local.json",
        .data = "{ \"midi_name_filter\": tru }",
    });

    const base_path = try tmp_dir.parent_dir.realPathFileAlloc(io, &tmp_dir.sub_path, allocator);
    defer allocator.free(base_path);

    const result = AppConfig.loadWithFallbackAtPath(allocator, io, base_path);
    try std.testing.expectError(error.UnexpectedToken, result);
}
