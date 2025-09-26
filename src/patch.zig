const std = @import("std");
const utils = @import("./utils.zig");

pub const PatchSet = struct {
    patches: []PatchSetEntry,
    dir: ?[]const u8 = null,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(@This()) {
        var parsed_patch_set = try utils.loadJSON(@This(), allocator, path);
        if (parsed_patch_set.value.dir == null) {
            parsed_patch_set.value.dir = try parsed_patch_set.arena.allocator().dupe(u8, std.fs.path.dirname(path) orelse "");
        }
        return parsed_patch_set;
    }

    pub fn has_midi_program(self: @This(), program: u7) bool {
        for (self.patches) |patch| {
            if (patch.program == program) {
                return true;
            }
        }
        return false;
    }

    pub fn loadPatch(self: @This(), allocator: std.mem.Allocator, program: u7) !Patch {
        for (self.patches) |patch| {
            if (patch.program == program) {
                const complete_patch_path = try std.fs.path.join(allocator, &.{ self.dir.?, patch.file });
                defer allocator.free(complete_patch_path);
                const parsed_patch_config = try PatchConfig.load(allocator, complete_patch_path);
                return .{
                    .config = parsed_patch_config,
                    .path = try parsed_patch_config.arena.allocator().dupe(u8, complete_patch_path),
                };
            }
        }
        return error.ProgramNotFound;
    }
};

const PatchSetEntry = struct {
    program: u7,
    file: [:0]u8,
};

pub const Patch = struct {
    config: std.json.Parsed(PatchConfig),
    path: []u8,

    pub fn channels(self: @This()) []ChannelConfig {
        return self.config.value.channels;
    }

    pub fn deinit(self: @This()) void {
        self.config.deinit();
    }
};

pub const PatchConfig = struct {
    volume: f32 = 1.0,
    channels: []ChannelConfig,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(@This()) {
        return utils.loadJSON(@This(), allocator, path);
    }
};

const ChannelConfig = struct {
    volume: f32 = 1.0,
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

    try std.testing.expectEqualDeep(0.98, patch_config.volume);
    try std.testing.expectEqualDeep(0.99, patch_config.channels[0].volume);
    try std.testing.expectEqualDeep("http://tytel.org/helm", patch_config.channels[0].plugins[0].uri);
}

test "load two-synth.json" {
    const allocator = std.testing.allocator;

    const parsed_patch_config = try PatchConfig.load(allocator, "patches/demo/two-synths.json");
    defer parsed_patch_config.deinit();

    const patch_config = parsed_patch_config.value;

    try std.testing.expectEqualDeep(1.0, patch_config.volume);
    try std.testing.expectEqualDeep(1.0, patch_config.channels[0].volume);

    try std.testing.expectEqualDeep("http://tytel.org/helm", patch_config.channels[0].plugins[0].uri);
    try std.testing.expectEqualDeep("https://surge-synthesizer.github.io/lv2/surge-xt", patch_config.channels[1].plugins[0].uri);
}

test "PatchSet.loadPatch" {
    const allocator = std.testing.allocator;

    // Load the PatchSet from the "patches/demo" directory
    var parsed_patch_set = try PatchSet.load(allocator, "patches/demo/patch-set.json");
    const patch_set = parsed_patch_set.value;
    defer parsed_patch_set.deinit();

    // Test loading a valid patch
    const patch = try patch_set.loadPatch(allocator, 0);
    defer patch.deinit();

    try std.testing.expectEqualDeep("http://tytel.org/helm", patch.channels()[0].plugins[0].uri);

    // Test loading a non-existent program
    const result = patch_set.loadPatch(allocator, 3);
    try std.testing.expect(result == error.ProgramNotFound);
}
