const std = @import("std");

pub const c = @cImport({
    @cInclude("lilv-0/lilv/lilv.h");
    @cInclude("lv2/core/lv2.h");
    @cInclude("lv2/atom/atom.h");
    @cInclude("lv2/midi/midi.h");
    @cInclude("lv2/urid/urid.h");
    @cInclude("lv2/ui/ui.h");
    @cInclude("suil-0/suil/suil.h");
    @cInclude("dlfcn.h");
});

const UriTable = std.StringHashMap(c_uint);

pub const Lv2Host = struct {
    allocator: std.mem.Allocator,
    world: *c.LilvWorld,
    uri_table: UriTable,
    urid_map: c.LV2_URID_Map,
    urid_unmap: c.LV2_URID_Unmap,
    urid_map_feature: c.LV2_Feature,
    urid_map_features: [2]?*const c.LV2_Feature,

    pub fn mapUri(self: *Lv2Host, uri: [:0]const u8) c.LV2_URID {
        return self.mapUriImpl(uri.ptr);
    }

    pub fn unmapUri(self: *Lv2Host, urid: c.LV2_URID) ?[*:0]const u8 {
        return self.unmapUriImpl(urid);
    }

    pub fn worldPtr(self: *Lv2Host) *c.LilvWorld {
        return self.world;
    }

    pub fn featurePtr(self: *Lv2Host) [*c]?*const c.LV2_Feature {
        return @ptrCast(self.urid_map_features[0..].ptr);
    }

    pub fn uridMap(self: *Lv2Host) *c.LV2_URID_Map {
        return &self.urid_map;
    }

    pub fn uridUnmap(self: *Lv2Host) *c.LV2_URID_Unmap {
        return &self.urid_unmap;
    }

    pub fn deinit(self: *Lv2Host) void {
        self.freeUriTable();
        c.lilv_world_free(self.world);
        self.allocator.destroy(self);
    }

    fn mapUriImpl(self: *Lv2Host, uri: [*:0]const u8) c.LV2_URID {
        const slice = std.mem.span(uri);
        if (self.uri_table.get(slice)) |found| return found;

        const dup = std.heap.page_allocator.dupeZ(u8, slice) catch return 0;
        errdefer std.heap.page_allocator.free(dup);

        const new_id: c.LV2_URID = @intCast(self.uri_table.count() + 1);
        self.uri_table.put(dup, new_id) catch {
            std.heap.page_allocator.free(dup);
            return 0;
        };

        return new_id;
    }

    fn unmapUriImpl(self: *Lv2Host, urid: c.LV2_URID) ?[*:0]const u8 {
        var it = self.uri_table.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == urid) {
                const key_slice = entry.key_ptr.*;
                return @ptrCast(key_slice.ptr);
            }
        }
        return null;
    }

    fn freeUriTable(self: *Lv2Host) void {
        var it = self.uri_table.iterator();
        while (it.next()) |entry| {
            const key_slice = entry.key_ptr.*;
            const len_with_terminator = key_slice.len + 1;
            const key_mut: [*]u8 = @constCast(key_slice.ptr);
            std.heap.page_allocator.free(key_mut[0..len_with_terminator]);
        }
        self.uri_table.deinit();
    }
};

var host_instance: ?*Lv2Host = null;

pub fn initGlobal(allocator: std.mem.Allocator) !*Lv2Host {
    if (host_instance) |existing| return existing;

    var host = try allocator.create(Lv2Host);
    errdefer allocator.destroy(host);

    host.* = .{
        .allocator = allocator,
        .world = undefined,
        .uri_table = UriTable.init(allocator),
        .urid_map = undefined,
        .urid_unmap = undefined,
        .urid_map_feature = undefined,
        .urid_map_features = undefined,
    };

    errdefer host.freeUriTable();

    host.world = c.lilv_world_new() orelse return error.LilvWorldNewFailed;
    errdefer c.lilv_world_free(host.world);

    c.lilv_world_load_all(host.world);

    host.urid_map = .{ .handle = host, .map = urid_map_func };
    host.urid_unmap = .{ .handle = host, .unmap = urid_unmap_func };
    host.urid_map_feature = .{ .URI = "http://lv2plug.in/ns/ext/urid#map", .data = &host.urid_map };
    host.urid_map_features = .{ &host.urid_map_feature, null };

    host_instance = host;
    return host;
}

pub fn get() *Lv2Host {
    return host_instance orelse @panic("Lv2Host not initialized");
}

pub fn deinitGlobal() void {
    if (host_instance) |host| {
        host.deinit();
        host_instance = null;
    }
}

fn hostFromHandle(handle: ?*anyopaque) ?*Lv2Host {
    if (handle) |ptr| return @ptrCast(@alignCast(ptr));
    return host_instance;
}

export fn urid_map_func(handle: ?*anyopaque, uri: ?[*:0]const u8) callconv(.c) c.LV2_URID {
    if (uri == null) return 0;
    const host = hostFromHandle(handle) orelse return 0;
    return host.mapUriImpl(uri.?);
}

export fn urid_unmap_func(handle: ?*anyopaque, urid: c.LV2_URID) callconv(.c) ?[*:0]const u8 {
    const host = hostFromHandle(handle) orelse return null;
    return host.unmapUriImpl(urid);
}
