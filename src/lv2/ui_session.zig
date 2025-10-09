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
pub const EXT_UI_WIDGET_URI = "http://kxstudio.sf.net/ns/lv2ext/external-ui#Widget";
pub const X11_UI_URI = "http://lv2plug.in/ns/extensions/ui#X11UI";

const default_host_type_uris = [_][*:0]const u8{
    EXT_UI_WIDGET_URI,
    c.LV2_UI__GtkUI,
    c.LV2_UI__Gtk3UI,
    c.LV2_UI__Qt4UI,
    c.LV2_UI__Qt5UI,
    c.LV2_UI__WindowsUI,
    c.LV2_UI__CocoaUI,
    c.LV2_UI__X11UI,
};

const default_ui_type_uris = [_][*:0]const u8{
    EXT_UI_WIDGET_URI,
    c.LV2_UI__GtkUI,
    c.LV2_UI__Gtk3UI,
    c.LV2_UI__Qt4UI,
    c.LV2_UI__Qt5UI,
    c.LV2_UI__WindowsUI,
    c.LV2_UI__CocoaUI,
    c.LV2_UI__X11UI,
};

var gtk_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub const UiSession = struct {
    const Self = @This();
    const UiKind = enum { external, gtk, x11 };
    const ContainerKind = enum { external, gtk2, gtk3 };

    pub const SessionContext = struct {
        allocator: std.mem.Allocator,
        world: *c.LilvWorld,
        plugin_uri_string: []const u8,
        plugin_uri: *c.LilvNode,
        plugin: *const c.LilvPlugin,
        instance: [*c]c.LilvInstance,
        control_in_vals: []f32,
    };

    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ctx: SessionContext = undefined,
    ui_kind: UiKind = undefined,
    container_kind: ContainerKind = .external,
    ext: ?*LV2_External_UI_Widget = null,
    suil_instance: *c.SuilInstance = undefined,

    host: *c.SuilHost = undefined,
    ext_host: LV2_External_UI_Host = undefined,
    ext_host_feat: c.LV2_Feature = undefined,
    instance_access_feat: c.LV2_Feature = undefined,
    features: [8]?*const c.LV2_Feature = undefined,
    gtk_window: ?*c.GtkWidget = null,
    gtk_widget: ?*c.GtkWidget = null,

    pub const SupportedUiCombination = struct {
        host_type_uri: []const u8,
        ui_type_uri: []const u8,
        quality: c_uint,
    };

    pub fn findSupportedUiCombinations(allocator: std.mem.Allocator) ![]SupportedUiCombination {
        var list = std.ArrayList(SupportedUiCombination){};
        errdefer list.deinit(allocator);

        for (default_host_type_uris) |host_uri| {
            for (default_ui_type_uris) |ui_uri| {
                const quality: c_uint = c.suil_ui_supported(host_uri, ui_uri);
                if (quality == 0) continue;

                try list.append(allocator, .{
                    .host_type_uri = std.mem.sliceTo(host_uri, 0),
                    .ui_type_uri = std.mem.sliceTo(ui_uri, 0),
                    .quality = quality,
                });
            }
        }

        return list.toOwnedSlice(allocator);
    }

    pub fn init(self: *Self, ctx: SessionContext) !void {
        self.ctx = ctx;
        self.ext = null;
        self.gtk_window = null;
        self.gtk_widget = null;

        try Self.listUIs(ctx);

        const ui_selection = try Self.chooseUi(ctx.world, ctx.plugin);
        self.ui_kind = ui_selection.kind;

        const resources = try Self.resolveUiResources(ctx, ui_selection.ui);
        defer resources.deinit(ctx.allocator);

        const container_choice = try self.determineContainer(ui_selection.type_uri);

        const host_ptr = try self.createSuilHost();
        errdefer c.suil_host_free(host_ptr);

        self.populateFeatureList(c.lilv_instance_get_handle(ctx.instance) orelse return error.NoInstanceHandle);

        const suil_instance = c.suil_instance_new(
            host_ptr,
            self,
            container_choice.uri,
            resources.plugin_uri_c,
            resources.ui_uri_c,
            ui_selection.type_uri,
            resources.bundle_path,
            resources.binary_path,
            @ptrCast(&self.features[0]),
        ) orelse {
            std.log.err("suil_instance_new failed for UI {s} in {s}", .{ std.mem.span(resources.ui_uri_c), resources.binary_path });
            return error.SomeError;
        };
        errdefer c.suil_instance_free(suil_instance);

        self.suil_instance = suil_instance;

        const widget_ptr = c.suil_instance_get_widget(suil_instance);
        self.closed.store(false, .seq_cst);

        switch (self.container_kind) {
            .external => {
                const ext = Self.asExt(widget_ptr);
                self.ext = ext;

                std.debug.print("Show UI ({s})\n", .{self.uiKindName()});
                if (ext.show) |show_fn| {
                    show_fn(ext);
                } else {
                    std.debug.print("External UI provided no show() implementation.\n", .{});
                }
            },
            .gtk2, .gtk3 => {
                const gtk_widget = Self.asGtk(widget_ptr) orelse {
                    std.log.err("suil returned null Gtk widget for UI {s}", .{std.mem.span(resources.ui_uri_c)});
                    return error.UiWidgetUnavailable;
                };
                try self.setupGtkWindow(gtk_widget, resources.plugin_uri_c);
            },
        }
    }

    const UiSelection = struct {
        ui: *const c.LilvUI,
        kind: UiKind,
        type_uri: [*:0]const u8,
    };

    fn chooseUi(world: *c.LilvWorld, plugin: *const c.LilvPlugin) !UiSelection {
        const ext_ui = c.lilv_new_uri(world, EXT_UI_WIDGET_URI) orelse return error.SomeError;
        defer c.lilv_node_free(ext_ui);

        const gtk3_ui = c.lilv_new_uri(world, c.LV2_UI__Gtk3UI) orelse return error.SomeError;
        defer c.lilv_node_free(gtk3_ui);

        const gtk2_ui = c.lilv_new_uri(world, c.LV2_UI__GtkUI) orelse return error.SomeError;
        defer c.lilv_node_free(gtk2_ui);

        const x11_ui = c.lilv_new_uri(world, X11_UI_URI) orelse return error.SomeError;
        defer c.lilv_node_free(x11_ui);

        const uis = c.lilv_plugin_get_uis(plugin);
        var gtk_candidate: ?UiSelection = null;
        var x11_candidate: ?UiSelection = null;

        var it = c.lilv_uis_begin(uis);
        while (!c.lilv_uis_is_end(uis, it)) : (it = c.lilv_uis_next(uis, it)) {
            const ui_ptr = c.lilv_uis_get(uis, it) orelse continue;

            if (c.lilv_ui_is_a(ui_ptr, ext_ui)) {
                return .{ .ui = ui_ptr, .kind = .external, .type_uri = EXT_UI_WIDGET_URI };
            }
            if (c.lilv_ui_is_a(ui_ptr, gtk3_ui)) {
                gtk_candidate = .{ .ui = ui_ptr, .kind = .gtk, .type_uri = c.LV2_UI__Gtk3UI };
                continue;
            }
            if (gtk_candidate == null and c.lilv_ui_is_a(ui_ptr, gtk2_ui)) {
                gtk_candidate = .{ .ui = ui_ptr, .kind = .gtk, .type_uri = c.LV2_UI__GtkUI };
                continue;
            }
            if (x11_candidate == null and c.lilv_ui_is_a(ui_ptr, x11_ui)) {
                x11_candidate = .{ .ui = ui_ptr, .kind = .x11, .type_uri = X11_UI_URI };
            }
        }

        if (gtk_candidate) |candidate| return candidate;
        if (x11_candidate) |candidate| return candidate;

        return error.NoSupportedUiFound;
    }

    const UiResources = struct {
        plugin_uri_c: [*c]const u8,
        ui_uri_c: [*c]const u8,
        binary_path: [:0]u8,
        bundle_path: [:0]u8,

        fn deinit(self: UiResources, allocator: std.mem.Allocator) void {
            allocator.free(self.binary_path);
            allocator.free(self.bundle_path);
        }
    };

    fn resolveUiResources(ctx: SessionContext, ui: *const c.LilvUI) !UiResources {
        const plugin_uri_c = c.lilv_node_as_uri(ctx.plugin_uri) orelse return error.SomeError;
        const ui_uri_node = c.lilv_ui_get_uri(ui);
        const ui_uri_c = c.lilv_node_as_uri(ui_uri_node) orelse return error.SomeError;
        const binary_uri_node = c.lilv_ui_get_binary_uri(ui);
        const binary_uri_c = c.lilv_node_as_uri(binary_uri_node) orelse return error.SomeError;
        const bundle_uri_node = c.lilv_ui_get_bundle_uri(ui);
        const bundle_uri_c = c.lilv_node_as_uri(bundle_uri_node) orelse return error.SomeError;

        const binary_path = try utils.convertUriToPath(ctx.allocator, binary_uri_c);
        errdefer ctx.allocator.free(binary_path);
        const bundle_path = try utils.convertUriToPath(ctx.allocator, bundle_uri_c);
        errdefer ctx.allocator.free(bundle_path);

        std.debug.print("binary_path_c {s}\n", .{binary_path});
        std.debug.print("bundle_path_c {s}\n", .{bundle_path});

        return UiResources{
            .plugin_uri_c = plugin_uri_c,
            .ui_uri_c = ui_uri_c,
            .binary_path = binary_path,
            .bundle_path = bundle_path,
        };
    }

    fn determineContainer(self: *Self, ui_type_uri: [*:0]const u8) !ContainerChoice {
        const container_choice = selectContainerType(ui_type_uri) orelse {
            std.log.err("No Suil support for UI type {s}", .{std.mem.sliceTo(ui_type_uri, 0)});
            return error.UiTypeNotSupported;
        };

        if (container_choice.kind == .gtk2 or container_choice.kind == .gtk3) {
            try ensureGtkInitialized();
        }

        self.container_kind = container_choice.kind;

        std.debug.print(
            "Using Suil host {s} for UI type {s}\n",
            .{
                std.mem.sliceTo(container_choice.uri, 0),
                std.mem.sliceTo(ui_type_uri, 0),
            },
        );

        return container_choice;
    }

    fn createSuilHost(self: *Self) !*c.SuilHost {
        const host_ptr = c.suil_host_new(Self.uiWrite, Self.uiIndex, Self.uiSubscribe, Self.uiUnsubscribe) orelse return error.SomeError;
        self.host = host_ptr;
        self.ext_host = LV2_External_UI_Host{ .ui_closed = Self.onUiClosed };
        self.ext_host_feat = c.LV2_Feature{
            .URI = EXT_UI_HOST_URI,
            .data = &self.ext_host,
        };

        return host_ptr;
    }

    fn populateFeatureList(self: *Self, lv2_handle: *anyopaque) void {
        self.instance_access_feat = c.LV2_Feature{
            .URI = "http://lv2plug.in/ns/ext/instance-access",
            .data = lv2_handle,
        };

        const lv2_host_features = host.get().featurePtr();

        var feature_count: usize = 0;
        self.features = .{ null, null, null, null, null, null, null, null };

        if (self.ui_kind == .external) {
            self.features[feature_count] = &self.ext_host_feat;
            feature_count += 1;
        }

        self.features[feature_count] = &self.instance_access_feat;
        feature_count += 1;

        var cursor = lv2_host_features;
        while (true) {
            const feature_ptr = cursor[0];
            if (feature_ptr == null) break;
            std.debug.assert(feature_count < self.features.len - 1);
            self.features[feature_count] = feature_ptr;
            feature_count += 1;
            cursor += 1;
        }

        self.features[feature_count] = null;
    }

    const ContainerChoice = struct {
        uri: [*:0]const u8,
        kind: ContainerKind,
    };

    fn selectContainerType(ui_type_uri: [*:0]const u8) ?ContainerChoice {
        const host_candidates = [_]ContainerChoice{
            .{ .uri = EXT_UI_WIDGET_URI, .kind = .external },
            .{ .uri = c.LV2_UI__Gtk3UI, .kind = .gtk3 },
            .{ .uri = c.LV2_UI__GtkUI, .kind = .gtk2 },
        };

        var best_choice: ?ContainerChoice = null;
        var best_quality: c_uint = std.math.maxInt(c_uint);

        for (host_candidates) |candidate| {
            const quality = c.suil_ui_supported(candidate.uri, ui_type_uri);
            if (quality == 0) continue;
            if (best_choice == null or quality < best_quality) {
                best_choice = candidate;
                best_quality = quality;
                continue;
            }

            if (quality == best_quality and best_choice.?.kind != .external and candidate.kind == .external) {
                best_choice = candidate;
            }
        }

        return best_choice;
    }

    pub fn isClosed(self: *Self) bool {
        return self.closed.load(.seq_cst);
    }

    pub fn deinit(self: *Self) void {
        std.debug.print("Closing UI {s} ... \n", .{self.ctx.plugin_uri_string});
        switch (self.container_kind) {
            .external => {
                if (self.ext) |ext| {
                    if (ext.hide) |hide_fn| {
                        hide_fn(ext);
                    } else {
                        std.debug.print("External UI provided no hide() implementation.\n", .{});
                    }
                }
            },
            .gtk2, .gtk3 => {
                if (self.gtk_window) |window| {
                    c.gtk_widget_destroy(window);
                    self.gtk_window = null;
                    self.gtk_widget = null;
                }
            },
        }
        c.suil_host_free(self.host);
        c.suil_instance_free(self.suil_instance);
        self.closed.store(true, .seq_cst);
        std.debug.print("UI {s} Closed\n", .{self.ctx.plugin_uri_string});
    }

    fn listUIs(ctx: SessionContext) !void {
        const plugin = ctx.plugin;

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

    fn asGtk(widget_ptr: ?*anyopaque) ?*c.GtkWidget {
        const p = widget_ptr orelse return null;
        const aligned: *align(@alignOf(c.GtkWidget)) anyopaque = @alignCast(p);
        return @as(*c.GtkWidget, @ptrCast(aligned));
    }

    fn setupGtkWindow(self: *Self, gtk_widget: *c.GtkWidget, title: [*:0]const u8) !void {
        const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL) orelse {
            std.log.err("Failed to create Gtk window for UI {s}", .{title});
            return error.GtkWindowCreateFailed;
        };

        self.gtk_widget = gtk_widget;
        self.gtk_window = window;

        const container: *c.GtkContainer = @ptrCast(@alignCast(window));
        c.gtk_container_add(container, gtk_widget);

        const gtk_window_ptr: *c.GtkWindow = @ptrCast(@alignCast(window));
        c.gtk_window_set_title(gtk_window_ptr, title);
        c.gtk_widget_show_all(window);

        _ = c.g_signal_connect_data(
            @ptrCast(window),
            "destroy",
            @ptrCast(&Self.onGtkDestroy),
            self,
            null,
            0,
        );

        std.debug.print("Show UI ({s})\n", .{self.uiKindName()});
    }

    fn uiKindName(self: *Self) []const u8 {
        return switch (self.ui_kind) {
            .external => "external",
            .gtk => "gtk",
            .x11 => "x11",
        };
    }

    fn ensureGtkInitialized() !void {
        if (gtk_initialized.load(.acquire)) return;

        const already = gtk_initialized.swap(true, .acq_rel);
        if (already) return;

        if (c.gtk_init_check(null, null) == 0) {
            gtk_initialized.store(false, .release);
            std.log.err("gtk_init_check failed; cannot host Gtk-based UIs", .{});
            return error.GtkInitFailed;
        }
    }

    pub fn pumpGtkEvents() void {
        if (!gtk_initialized.load(.acquire)) return;

        while (c.gtk_events_pending() != 0) {
            _ = c.gtk_main_iteration_do(0);
        }
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
        const control_in_vals = sess.*.ctx.control_in_vals;
        if (port_index < control_in_vals.len and protocol == 0 and buffer != null and buffer_size == @sizeOf(f32)) {
            const fptr: *const f32 = @ptrCast(@alignCast(buffer.?));
            control_in_vals[port_index] = fptr.*;
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

    fn onGtkDestroy(_: ?*c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
        if (data) |ptr| {
            const sess: *Self = @ptrCast(@alignCast(ptr));
            sess.closed.store(true, .seq_cst);
            sess.gtk_window = null;
            sess.gtk_widget = null;
        }
    }
};

test "findSupportedUiCombinations enumerates supported host/ui pairs" {
    const combos = try UiSession.findSupportedUiCombinations(std.testing.allocator);
    defer std.testing.allocator.free(combos);

    for (combos) |combo| {
        std.debug.print(
            "supported host={s} ui={s} quality={d}\n",
            .{ combo.host_type_uri, combo.ui_type_uri, combo.quality },
        );
    }

    var expected_count: usize = 0;

    for (default_host_type_uris) |host_uri| {
        const host_slice = std.mem.sliceTo(host_uri, 0);
        for (default_ui_type_uris) |ui_uri| {
            const ui_slice = std.mem.sliceTo(ui_uri, 0);
            const quality: c_uint = c.suil_ui_supported(host_uri, ui_uri);
            if (quality != 0) {
                expected_count += 1;
            }

            var found: ?usize = null;
            var idx: usize = 0;
            while (idx < combos.len) : (idx += 1) {
                const combo = combos[idx];
                if (std.mem.eql(u8, combo.host_type_uri, host_slice) and
                    std.mem.eql(u8, combo.ui_type_uri, ui_slice))
                {
                    found = idx;
                    break;
                }
            }

            if (quality != 0) {
                try std.testing.expect(found != null);
                try std.testing.expectEqual(quality, combos[found.?].quality);
            } else {
                try std.testing.expect(found == null);
            }
        }
    }

    try std.testing.expectEqual(expected_count, combos.len);
}
