const std = @import("std");
const utils = @import("./utils.zig");

const AppConfig = struct {
    midi_name_filter: ?[]u8,

    pub fn loadWithFallback(allocator: std.mem.Allocator) !std.json.Parsed(AppConfig) {
        return AppConfig.load(allocator, "config.local.json") catch {
            return AppConfig.load(allocator, "config.json");
        };
    }

    fn load(
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !std.json.Parsed(AppConfig) {
        return utils.loadJSON(AppConfig, allocator, path);
    }
};

// ============= Tests ===============

test "AppConfig.load" {
    const allocator = std.testing.allocator;

    const parsed_config = try AppConfig.load(allocator, "src/_test_data/config.json");
    defer parsed_config.deinit();

    const app_config = parsed_config.value;

    try std.testing.expectEqualDeep("Midi Through Port-0", app_config.midi_name_filter);
}

test "AppConfig.loadWithFallback" {
    const allocator = std.testing.allocator;

    const parsed_config = try AppConfig.loadWithFallback(allocator);
    defer parsed_config.deinit();
}
