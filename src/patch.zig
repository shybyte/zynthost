const std = @import("std");

const PatchConfig = struct {
    channels: []ChannelConfig,
};

const ChannelConfig = struct {
    plugins: []PluginConfig,
};

const PluginConfig = struct {
    uri: [:0]u8,
};

pub fn loadPatch(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(PatchConfig) {
    const file_content = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(file_content);
    return std.json.parseFromSlice(PatchConfig, allocator, file_content, .{});
}

// ============= Tests ===============

test "load one-synth.json" {
    const allocator = std.testing.allocator;

    const parsed_patch_config = try loadPatch(allocator, "patches/demo/one-synth.json");
    defer parsed_patch_config.deinit();

    const patch_config = parsed_patch_config.value;

    try std.testing.expectEqualDeep("http://tytel.org/helm", patch_config.channels[0].plugins[0].uri);
}

test "load two-synth.json" {
    const allocator = std.testing.allocator;

    const parsed_patch_config = try loadPatch(allocator, "patches/demo/two-synths.json");
    defer parsed_patch_config.deinit();

    const patch_config = parsed_patch_config.value;

    try std.testing.expectEqualDeep("http://tytel.org/helm", patch_config.channels[0].plugins[0].uri);
    try std.testing.expectEqualDeep("https://surge-synthesizer.github.io/lv2/surge-xt", patch_config.channels[1].plugins[0].uri);
}
