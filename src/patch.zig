const std = @import("std");
const utils = @import("./utils.zig");

pub const PatchSet = struct {
    entries: []PatchSetEntry,
};

pub const PatchSetEntry = struct {
    program: u7,
    patch_config_file_name: [:0]u8,
};

pub const PatchConfig = struct {
    channels: []ChannelConfig,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(@This()) {
        return utils.loadJSON(@This(), allocator, path);
    }
};

const ChannelConfig = struct {
    plugins: []PluginConfig,
};

const PluginConfig = struct {
    uri: [:0]u8,
};

// Example: (patchname.json,1) => patchname-channel-1.ttl
pub fn get_plugin_patch_file_name(
    allocator: std.mem.Allocator,
    patch_file_name: []const u8,
    channel: u4,
) ![:0]u8 {
    const dirname = std.fs.path.dirname(patch_file_name) orelse ".";
    const basename = std.fs.path.stem(patch_file_name);
    return std.fmt.allocPrintSentinel(
        allocator,
        "{s}/{s}-channel-{d}.ttl",
        .{ dirname, basename, channel },
        0,
    );
}

// ============= Tests ===============

test "get_plugin_patch_file_name" {
    const allocator = std.testing.allocator;

    const result = try get_plugin_patch_file_name(allocator, "folder/patchname.json", 1);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("folder/patchname-channel-1.ttl", result);
}

test "load one-synth.json" {
    const allocator = std.testing.allocator;

    const parsed_patch_config = try PatchConfig.load(allocator, "patches/demo/one-synth.json");
    defer parsed_patch_config.deinit();

    const patch_config = parsed_patch_config.value;

    try std.testing.expectEqualDeep("http://tytel.org/helm", patch_config.channels[0].plugins[0].uri);
}

test "load two-synth.json" {
    const allocator = std.testing.allocator;

    const parsed_patch_config = try PatchConfig.load(allocator, "patches/demo/two-synths.json");
    defer parsed_patch_config.deinit();

    const patch_config = parsed_patch_config.value;

    try std.testing.expectEqualDeep("http://tytel.org/helm", patch_config.channels[0].plugins[0].uri);
    try std.testing.expectEqualDeep("https://surge-synthesizer.github.io/lv2/surge-xt", patch_config.channels[1].plugins[0].uri);
}
