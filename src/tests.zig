const std = @import("std");
const cfg = @import("cfg");

test {
    // If -Donly=... is given, choose exactly one file at COMPILE TIME.
    comptime if (cfg.only) |p| {
        if (std.mem.endsWith(u8, p, "midi_input.zig")) {
            _ = @import("midi_input.zig");
        } else if (std.mem.endsWith(u8, p, "lv2/midi_sequence.zig")) {
            _ = @import("lv2/midi_sequence.zig");
        } else if (std.mem.endsWith(u8, p, "lv2/synth_plugin.zig")) {
            _ = @import("lv2/synth_plugin.zig");
        } else if (std.mem.endsWith(u8, p, "patch.zig")) {
            _ = @import("patch.zig");
        } else {
            @compileError("unknown -Donly value: " ++ p);
        }
    } else {
        // Default: import them all
        _ = @import("midi.zig");
        _ = @import("midi_input.zig");
        _ = @import("lv2/midi_sequence.zig");
        _ = @import("lv2/synth_plugin.zig");
        _ = @import("patch.zig");
    };
}
