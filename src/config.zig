const std = @import("std");

const AppConfig = struct {
    midi_name_filter: ?[]u8,
};

pub fn loadAppConfigWithFallback(allocator: std.mem.Allocator) !std.json.Parsed(AppConfig) {
    return loadAppConfig(allocator, "config.local.json") catch {
        return loadAppConfig(allocator, "config.json");
    };
}

fn loadAppConfig(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(AppConfig) {
    const file_content = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(file_content);
    return std.json.parseFromSlice(AppConfig, allocator, file_content, .{});
}

// ============= Tests ===============

test loadAppConfig {
    const allocator = std.testing.allocator;

    const parsed_config = try loadAppConfig(allocator, "src/_test_data/config.json");
    defer parsed_config.deinit();

    const app_config = parsed_config.value;

    try std.testing.expectEqualDeep("Midi Through Port-0", app_config.midi_name_filter);
}

test loadAppConfigWithFallback {
    const allocator = std.testing.allocator;

    const parsed_config = try loadAppConfigWithFallback(allocator);
    defer parsed_config.deinit();
}
