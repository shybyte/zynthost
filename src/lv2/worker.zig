const std = @import("std");
const c = @import("c");
const MessageQueue = @import("message_queue.zig").MessageQueue;

/// One worker per plugin instance, with work on a background thread and
/// responses delivered only by the audio thread between calls to run().
pub const Worker = struct {
    requests: MessageQueue,
    responses: MessageQueue,
    semaphore: c.sem_t = undefined,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    interface: ?*const c.LV2_Worker_Interface = null,
    handle: c.LV2_Handle = null,
    schedule: c.LV2_Worker_Schedule = undefined,
    feature: c.LV2_Feature = undefined,

    pub fn init(self: *Worker, allocator: std.mem.Allocator) !void {
        self.* = .{
            .requests = try MessageQueue.init(allocator),
            .responses = undefined,
        };
        errdefer self.requests.deinit(allocator);
        self.responses = try MessageQueue.init(allocator);
        errdefer self.responses.deinit(allocator);
        if (c.sem_init(&self.semaphore, 0, 0) != 0) return error.WorkerSemaphoreFailed;
        self.schedule = .{ .handle = self, .schedule_work = scheduleWork };
        self.feature = .{ .URI = c.LV2_WORKER__schedule, .data = &self.schedule };
    }

    pub fn start(self: *Worker, instance: [*c]c.LilvInstance) !void {
        const ptr = c.lilv_instance_get_extension_data(instance, c.LV2_WORKER__interface) orelse return;
        self.interface = @ptrCast(@alignCast(ptr));
        if (self.interface.?.work == null) return error.InvalidWorkerInterface;
        self.handle = c.lilv_instance_get_handle(instance);
        self.thread = try std.Thread.spawn(.{}, workLoop, .{self});
    }

    fn workLoop(self: *Worker) void {
        while (true) {
            while (c.sem_wait(&self.semaphore) != 0) {}
            if (self.requests.peek()) |message| {
                _ = self.interface.?.work.?(self.handle, respond, self, message.size, message.data[0..].ptr);
                self.requests.pop();
            } else if (self.stopping.load(.acquire)) return;
        }
    }

    fn scheduleWork(handle: ?*anyopaque, size: u32, data: ?*const anyopaque) callconv(.c) c.LV2_Worker_Status {
        const self: *Worker = @ptrCast(@alignCast(handle orelse return c.LV2_WORKER_ERR_UNKNOWN));
        if (self.stopping.load(.acquire)) return c.LV2_WORKER_ERR_UNKNOWN;
        const bytes = messageBytes(size, data) orelse return c.LV2_WORKER_ERR_UNKNOWN;
        if (!self.requests.push(0, 0, bytes)) return c.LV2_WORKER_ERR_NO_SPACE;
        _ = c.sem_post(&self.semaphore);
        return c.LV2_WORKER_SUCCESS;
    }

    fn respond(handle: ?*anyopaque, size: u32, data: ?*const anyopaque) callconv(.c) c.LV2_Worker_Status {
        const self: *Worker = @ptrCast(@alignCast(handle orelse return c.LV2_WORKER_ERR_UNKNOWN));
        const bytes = messageBytes(size, data) orelse return c.LV2_WORKER_ERR_UNKNOWN;
        return if (self.responses.push(0, 0, bytes)) c.LV2_WORKER_SUCCESS else c.LV2_WORKER_ERR_NO_SPACE;
    }

    fn messageBytes(size: u32, data: ?*const anyopaque) ?[]const u8 {
        if (size == 0) return &.{};
        const ptr: [*]const u8 = @ptrCast(data orelse return null);
        return ptr[0..size];
    }

    pub fn deliverResponses(self: *Worker) void {
        const interface = self.interface orelse return;
        for (0..MessageQueue.capacity) |_| {
            const message = self.responses.peek() orelse break;
            if (interface.work_response) |response| {
                _ = response(self.handle, message.size, message.data[0..].ptr);
            }
            self.responses.pop();
        }
    }

    pub fn endRun(self: *Worker) void {
        if (self.interface) |interface| {
            if (interface.end_run) |end_run| _ = end_run(self.handle);
        }
    }

    pub fn stop(self: *Worker) void {
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            _ = c.sem_post(&self.semaphore);
            thread.join();
            self.thread = null;
            self.deliverResponses();
        }
    }

    pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
        self.stop();
        _ = c.sem_destroy(&self.semaphore);
        self.requests.deinit(allocator);
        self.responses.deinit(allocator);
    }
};

test "Worker runs work off the audio thread, delivers responses on the caller, and drains on shutdown" {
    const Context = struct {
        work_thread: std.atomic.Value(std.Thread.Id) = .init(0),
        response_thread: std.Thread.Id = 0,
        responses: usize = 0,
        total: u32 = 0,

        fn work(handle: ?*anyopaque, respond_fn: c.LV2_Worker_Respond_Function, response_handle: ?*anyopaque, size: u32, data: ?*const anyopaque) callconv(.c) c.LV2_Worker_Status {
            const ctx: *@This() = @ptrCast(@alignCast(handle.?));
            ctx.work_thread.store(std.Thread.getCurrentId(), .release);
            return respond_fn.?(response_handle, size, data);
        }

        fn response(handle: ?*anyopaque, size: u32, data: ?*const anyopaque) callconv(.c) c.LV2_Worker_Status {
            const ctx: *@This() = @ptrCast(@alignCast(handle.?));
            if (size != 4) return c.LV2_WORKER_ERR_UNKNOWN;
            const value: *const u32 = @ptrCast(@alignCast(data.?));
            ctx.total += value.*;
            ctx.responses += 1;
            ctx.response_thread = std.Thread.getCurrentId();
            return c.LV2_WORKER_SUCCESS;
        }
    };
    var ctx = Context{};
    const interface = c.LV2_Worker_Interface{ .work = Context.work, .work_response = Context.response, .end_run = null };
    var worker: Worker = undefined;
    try worker.init(std.testing.allocator);
    defer worker.deinit(std.testing.allocator);
    worker.interface = &interface;
    worker.handle = &ctx;
    worker.thread = try std.Thread.spawn(.{}, Worker.workLoop, .{&worker});
    for (1..9) |i| {
        const value: u32 = @intCast(i);
        try std.testing.expectEqual(@as(c.LV2_Worker_Status, c.LV2_WORKER_SUCCESS), worker.schedule.schedule_work.?(worker.schedule.handle, 4, &value));
    }
    worker.stop();
    try std.testing.expect(ctx.work_thread.load(.acquire) != std.Thread.getCurrentId());
    try std.testing.expectEqual(std.Thread.getCurrentId(), ctx.response_thread);
    try std.testing.expectEqual(8, ctx.responses);
    try std.testing.expectEqual(36, ctx.total);
}
