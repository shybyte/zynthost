const std = @import("std");
const host = @import("host.zig");
const utils = @import("utils.zig");

const c = host.c;

pub const LV2_External_UI_Widget = extern struct {
    run: ?*const fn (?*anyopaque) callconv(.c) void,
    show: ?*const fn (?*anyopaque) callconv(.c) void,
    hide: ?*const fn (?*anyopaque) callconv(.c) void,
};

pub const LV2_External_UI_Host = extern struct {
    ui_closed: ?*const fn (?*anyopaque) callconv(.c) void,
    // Some versions add: ui_resize: ?*const fn (?*anyopaque, c_int, c_int) callconv(.C) c_int,
};

pub const EXT_UI_HOST_URI = "http://kxstudio.sf.net/ns/lv2ext/external-ui#Host";

// This SynthPluginType avoids circular imports.
pub fn UiSessionType(comptime SynthPluginType: type) type {
    return struct {
        const Self = @This();

        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        plugin: *SynthPluginType,
        ext: *LV2_External_UI_Widget = undefined,
        suil_instance: *c.SuilInstance = undefined,

        host: *c.SuilHost = undefined,
        ext_host: LV2_External_UI_Host = undefined,
        ext_host_feat: c.LV2_Feature = undefined,
        instance_access_feat: c.LV2_Feature = undefined,
        features: [3]?*const c.LV2_Feature = undefined,

        pub fn init(self: *Self) !void {
            const synth_plugin = self.plugin;
            const world = synth_plugin.world;
            const plugin = synth_plugin.plugin;

            const ext_ui_class = c.lilv_new_uri(world, "http://kxstudio.sf.net/ns/lv2ext/external-ui#Widget");
            defer c.lilv_node_free(ext_ui_class);

            try Self.listUIs(synth_plugin);

            const uis = c.lilv_plugin_get_uis(plugin);
            var it = c.lilv_uis_begin(uis);
            var ui: ?*const c.LilvUI = null;
            while (!c.lilv_uis_is_end(uis, it)) : (it = c.lilv_uis_next(uis, it)) {
                const u = c.lilv_uis_get(uis, it);
                if (c.lilv_ui_is_a(u, ext_ui_class)) {
                    ui = u;
                    break;
                }
            }
            if (ui == null) return error.NoExternalUiFound;

            const plugin_uri_c = c.lilv_node_as_uri(synth_plugin.plugin_uri);
            const ui_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_uri(ui.?));
            const ui_type_uri_c = "http://kxstudio.sf.net/ns/lv2ext/external-ui#Widget";

            const binary_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_binary_uri(ui.?)) orelse return error.SomeError;
            const binary_path_c = try utils.convertUriToPath(synth_plugin.allocator, binary_uri_c);
            defer synth_plugin.allocator.free(binary_path_c);
            std.debug.print("binary_path_c {s}\n", .{binary_path_c});

            const bundle_uri_c = c.lilv_node_as_uri(c.lilv_ui_get_bundle_uri(ui.?)) orelse return error.SomeError;
            const bundle_path_c = try utils.convertUriToPath(synth_plugin.allocator, bundle_uri_c);
            defer synth_plugin.allocator.free(bundle_path_c);
            std.debug.print("bundle_path_c {s}\n", .{bundle_path_c});

            self.host = c.suil_host_new(Self.uiWrite, Self.uiIndex, Self.uiSubscribe, Self.uiUnsubscribe) orelse return error.SomeError;
            errdefer c.suil_host_free(self.host);

            self.ext_host = LV2_External_UI_Host{ .ui_closed = Self.onUiClosed };
            self.ext_host_feat = c.LV2_Feature{
                .URI = EXT_UI_HOST_URI,
                .data = &self.ext_host,
            };

            const lv2_handle = c.lilv_instance_get_handle(synth_plugin.instance) orelse return error.NoInstanceHandle;

            self.instance_access_feat = c.LV2_Feature{
                .URI = "http://lv2plug.in/ns/ext/instance-access",
                .data = lv2_handle,
            };

            self.features = .{ &self.ext_host_feat, &self.instance_access_feat, null };

            const suil_instance = c.suil_instance_new(
                self.host,
                self,
                null,
                plugin_uri_c,
                ui_uri_c,
                ui_type_uri_c,
                bundle_path_c,
                binary_path_c,
                &self.features,
            ) orelse {
                std.log.err("suil_instance_new failed for UI {s} in {s}", .{ std.mem.span(ui_uri_c), binary_path_c });
                return error.SomeError;
            };
            errdefer c.suil_instance_free(suil_instance);

            self.suil_instance = suil_instance;

            const widget_ptr = c.suil_instance_get_widget(suil_instance);
            const ext = Self.asExt(widget_ptr);
            self.ext = ext;

            std.debug.print("Show UI\n", .{});
            self.closed.store(false, .seq_cst);
            ext.show.?(ext);
        }

        pub fn isClosed(self: *Self) bool {
            return self.closed.load(.seq_cst);
        }

        pub fn deinit(self: *Self) void {
            std.debug.print("Closing UI {s} ... \n", .{self.plugin.plugin_uri_string});
            self.ext.hide.?(self.ext);
            c.suil_host_free(self.host);
            c.suil_instance_free(self.suil_instance);
            std.debug.print("UI {s}] Closed\n", .{self.plugin.plugin_uri_string});
        }

        fn listUIs(synth_plugin: *SynthPluginType) !void {
            const plugin = synth_plugin.plugin;

            const uis = c.lilv_plugin_get_uis(plugin) orelse return error.PluginHasNoUIs;
            if (c.lilv_uis_size(uis) == 0) {
                std.debug.print("Plugin has no UIs.\n", .{});
                return;
            }

            var it = c.lilv_uis_begin(uis);
            var idx: usize = 0;
            while (!c.lilv_uis_is_end(uis, it)) : (it = c.lilv_uis_next(uis, it)) {
                const ui = c.lilv_uis_get(uis, it);
                if (ui == null) continue;

                const ui_uri = c.lilv_ui_get_uri(ui);
                const ui_uri_str = c.lilv_node_as_string(ui_uri);
                std.debug.print("UI #{d}: {s}\n", .{ idx, ui_uri_str });

                const classes = c.lilv_ui_get_classes(ui);
                var cit = c.lilv_nodes_begin(classes);
                while (!c.lilv_nodes_is_end(classes, cit)) : (cit = c.lilv_nodes_next(classes, cit)) {
                    const cls = c.lilv_nodes_get(classes, cit);
                    const cls_str = c.lilv_node_as_string(cls);
                    std.debug.print("    class: {s}\n", .{cls_str});
                }

                idx += 1;
            }
        }

        fn asExt(widget_ptr: ?*anyopaque) *LV2_External_UI_Widget {
            const p = widget_ptr orelse @panic("ExternalUI widget is null");
            const aligned: *align(@alignOf(LV2_External_UI_Widget)) anyopaque = @alignCast(p);
            return @as(*LV2_External_UI_Widget, @ptrCast(aligned));
        }

        pub fn uiWrite(
            controller: ?*anyopaque,
            port_index: u32,
            buffer_size: u32,
            protocol: u32,
            buffer: ?*const anyopaque,
        ) callconv(.c) void {
            std.debug.print("uiWrite portIndex {} {} {} {?}\n", .{ port_index, protocol, buffer_size, buffer });

            const sess: *Self = @ptrCast(@alignCast(controller));
            const plugin = sess.*.plugin;
            if (port_index < plugin.control_in_vals.len and protocol == 0 and buffer != null and buffer_size == @sizeOf(f32)) {
                const fptr: *const f32 = @ptrCast(@alignCast(buffer.?));
                plugin.control_in_vals[port_index] = fptr.*;
                std.debug.print("New val: {}\n", .{fptr.*});
            }
        }

        pub fn uiIndex(controller: ?*anyopaque, port_symbol: [*c]const u8) callconv(.c) u32 {
            _ = controller;
            std.debug.print("uiIndex port_symbol {s}\n", .{port_symbol});
            return 0;
        }

        pub fn uiSubscribe(
            controller: ?*anyopaque,
            port_index: u32,
            protocol: u32,
            features: [*c]const [*c]const c.LV2_Feature,
        ) callconv(.c) u32 {
            _ = controller;
            _ = port_index;
            _ = protocol;
            _ = features;
            return 0;
        }

        pub fn uiUnsubscribe(
            controller: ?*anyopaque,
            port_index: u32,
            protocol: u32,
            features: [*c]const [*c]const c.LV2_Feature,
        ) callconv(.c) u32 {
            _ = controller;
            _ = port_index;
            _ = protocol;
            _ = features;
            return 0;
        }

        fn onUiClosed(controller: ?*anyopaque) callconv(.c) void {
            if (controller) |p| {
                const sess: *Self = @ptrCast(@alignCast(p));
                sess.closed.store(true, .seq_cst);
            }
        }
    };
}
