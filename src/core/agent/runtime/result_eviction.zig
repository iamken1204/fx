//! Projects the within-turn suffix for one model request: tool results older
//! than the most recent steps become a short stub that carries a
//! `read_tool_result` handle. The canonical suffix, the session log, and the
//! recovery checkpoints keep the full text; only the request body changes.
//!
//! Eviction advances only when the un-evicted result bytes ahead of the kept
//! window reach `threshold_bytes`; one sweep then evicts everything except the
//! newest `keep_steps` steps. Between sweeps the projected prefix stays
//! byte-identical, so the provider prompt cache keeps hitting for as long as
//! the threshold allows.
const std = @import("std");
const types = @import("../../shared/types.zig");
const io_mod = @import("../../shared/io.zig");
const result_store = @import("../../session/result_store.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const env_name = "FX_KEEP_RECENT_RESULTS";
pub const threshold_env_name = "FX_EVICT_THRESHOLD_KB";
pub const default_threshold_bytes: usize = 256 * 1024;
pub const StorageTarget = result_store.StorageTarget;

/// Number of recent tool steps whose results survive a sweep; 0 disables eviction.
pub fn keepStepsFromEnv() usize {
    const value = io_mod.getenv(env_name) orelse return 0;
    return std.fmt.parseUnsigned(usize, std.mem.trim(u8, value, " \t"), 10) catch 0;
}

/// Evictable result bytes that trigger a sweep; unset or invalid falls back to
/// the default. An explicit 0 sweeps on every step.
pub fn thresholdBytesFromEnv() usize {
    const value = io_mod.getenv(threshold_env_name) orelse return default_threshold_bytes;
    const kb = std.fmt.parseUnsigned(usize, std.mem.trim(u8, value, " \t"), 10) catch
        return default_threshold_bytes;
    return kb * 1024;
}

/// One per turn. Stubs and stored handles live in the turn arena; each
/// projected slice lives in the scratch allocator handed to `view`.
pub const State = struct {
    turn_arena: Allocator,
    keep_steps: usize,
    threshold_bytes: usize,
    target: ?StorageTarget,
    /// Suffix messages before this index are projected as stubs.
    evicted_before: usize = 0,
    /// Stub text per evicted suffix index, built once.
    stubs: std.ArrayList(?[]const u8) = .empty,

    pub fn init(
        turn_arena: Allocator,
        keep_steps: usize,
        threshold_bytes: usize,
        target: ?StorageTarget,
    ) State {
        return .{
            .turn_arena = turn_arena,
            .keep_steps = keep_steps,
            .threshold_bytes = threshold_bytes,
            .target = target,
        };
    }

    /// Messages before `request_start` were already cut from the request by
    /// compaction, so they count toward neither the step window nor the
    /// threshold; the projection still covers them because callers slice by
    /// index.
    ///
    /// Returns `suffix` itself while nothing is evicted, otherwise a copy from
    /// `scratch` whose evicted tool results carry stub content.
    pub fn view(
        self: *State,
        scratch: Allocator,
        suffix: []const ChatMessage,
        request_start: usize,
    ) ![]const ChatMessage {
        if (self.keep_steps == 0) return suffix;

        const from = @max(self.evicted_before, @min(request_start, suffix.len));
        var total_steps: usize = 0;
        for (suffix[from..]) |message| {
            if (startsStep(message)) total_steps += 1;
        }
        if (total_steps > self.keep_steps) {
            // Sum the un-evicted result bytes ahead of the newest keep_steps
            // steps; sweep the whole region once they reach the threshold.
            const kept_from_step = total_steps - self.keep_steps + 1;
            var step: usize = 0;
            var cutoff: usize = from;
            var evictable_bytes: usize = 0;
            for (suffix[from..], from..) |message, index| {
                if (startsStep(message)) {
                    step += 1;
                    if (step == kept_from_step) {
                        cutoff = index;
                        break;
                    }
                } else if (message.role == .tool) {
                    if (message.content) |content| evictable_bytes += content.len;
                }
            }
            if (evictable_bytes >= self.threshold_bytes) self.evicted_before = cutoff;
        }
        if (self.evicted_before == 0) return suffix;

        const projected = try scratch.dupe(ChatMessage, suffix);
        for (projected[0..self.evicted_before], 0..) |*message, index| {
            if (message.role != .tool) continue;
            message.content = try self.stubFor(suffix[index], index);
        }
        return projected;
    }

    fn stubFor(self: *State, message: ChatMessage, index: usize) ![]const u8 {
        while (self.stubs.items.len <= index) try self.stubs.append(self.turn_arena, null);
        if (self.stubs.items[index]) |stub| return stub;

        const content = message.content orelse "";
        const tool_name = message.tool_name orelse "tool";
        const stub = if (try self.handleFor(message)) |handle|
            try std.fmt.allocPrint(
                self.turn_arena,
                "<tool_result_handle>{s}</tool_result_handle>\n{s} result ({d} bytes) cleared from the request to save context; use read_tool_result with this handle to read it again.",
                .{ handle, tool_name, content.len },
            )
        else
            try std.fmt.allocPrint(
                self.turn_arena,
                "{s} result ({d} bytes) cleared from the request to save context; run the tool again if you need it.",
                .{ tool_name, content.len },
            );
        self.stubs.items[index] = stub;
        return stub;
    }

    /// Reuses the handle of an already stored result; otherwise stores the
    /// text the model saw so the stub stays retrievable. Storage failures
    /// degrade to a handle-less stub instead of failing the turn.
    fn handleFor(self: *State, message: ChatMessage) !?[]const u8 {
        if (message.tool_result_memory) |memory| {
            if (memory.output_handle) |handle| return handle;
        }
        const target = self.target orelse return null;
        const content = message.content orelse return null;
        return target.store(
            self.turn_arena,
            message.tool_call_id orelse "call",
            message.tool_name orelse "tool",
            content,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => null,
        };
    }
};

fn startsStep(message: ChatMessage) bool {
    return message.role == .assistant and message.tool_calls.len > 0;
}

fn testStep(alloc: Allocator, list: *std.ArrayList(ChatMessage), step: usize) !void {
    const call_id = try std.fmt.allocPrint(alloc, "call-{d}", .{step});
    const calls = try alloc.alloc(types.ToolCall, 1);
    calls[0] = .{ .id = call_id, .name = "read_file", .arguments_json = "{}" };
    try list.append(alloc, .{ .role = .assistant, .content = "", .tool_calls = calls });
    try list.append(alloc, .{
        .role = .tool,
        .content = try std.fmt.allocPrint(alloc, "output of step {d}", .{step}),
        .tool_call_id = call_id,
        .tool_name = "read_file",
    });
}

fn handleIn(stub: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, stub, "<tool_result_handle>").? + "<tool_result_handle>".len;
    const end = std.mem.indexOfPos(u8, stub, start, "</tool_result_handle>").?;
    return stub[start..end];
}

test "view keeps the suffix verbatim below the threshold" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var suffix: std.ArrayList(ChatMessage) = .empty;
    var state = State.init(arena, 2, 1024, null);
    for (1..8) |step| try testStep(arena, &suffix, step);
    const same = try state.view(arena, suffix.items, 0);
    try std.testing.expectEqual(suffix.items.ptr, same.ptr);
    try std.testing.expectEqual(@as(usize, 0), state.evicted_before);
}

test "view sweeps all but the newest steps once the threshold fills" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try io_mod.dirRealpathAlloc(arena, tmp.dir, ".");

    var suffix: std.ArrayList(ChatMessage) = .empty;
    // Each test result is 16 bytes, so two evictable steps reach the threshold.
    var state = State.init(arena, 2, 32, .{ .legacy_dir = dir });
    for (1..5) |step| try testStep(arena, &suffix, step);
    const projected = try state.view(arena, suffix.items, 0);
    // Steps 1 and 2 are evicted; 3 and 4 stay verbatim.
    try std.testing.expectEqual(@as(usize, 4), state.evicted_before);
    try std.testing.expect(std.mem.startsWith(u8, handleIn(projected[1].content.?), "result-read_file-"));
    try std.testing.expect(std.mem.startsWith(u8, handleIn(projected[3].content.?), "result-read_file-"));
    try std.testing.expectEqualStrings("output of step 3", projected[5].content.?);
    try std.testing.expectEqualStrings("output of step 4", projected[7].content.?);
    // The canonical suffix is untouched and the stored file holds the model text.
    try std.testing.expectEqualStrings("output of step 1", suffix.items[1].content.?);
    const stored = try result_store.readByRange(arena, dir, handleIn(projected[1].content.?), 0, 64);
    try std.testing.expect(std.mem.indexOf(u8, stored, "\noutput of step 1\n") != null);

    // A fifth step leaves only step 3 evictable, below the threshold: the
    // boundary holds and the stub text is reused.
    try testStep(arena, &suffix, 5);
    const again = try state.view(arena, suffix.items, 0);
    try std.testing.expectEqual(@as(usize, 4), state.evicted_before);
    try std.testing.expectEqual(projected[1].content.?.ptr, again[1].content.?.ptr);
    try std.testing.expectEqualStrings("output of step 3", again[5].content.?);

    // The sixth step refills the threshold: steps 3 and 4 go too.
    try testStep(arena, &suffix, 6);
    const third = try state.view(arena, suffix.items, 0);
    try std.testing.expectEqual(@as(usize, 8), state.evicted_before);
    try std.testing.expect(std.mem.startsWith(u8, third[5].content.?, "<tool_result_handle>"));
    try std.testing.expectEqualStrings("output of step 5", third[9].content.?);
}

test "view reuses an existing stored handle and degrades without storage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var suffix: std.ArrayList(ChatMessage) = .empty;
    var state = State.init(arena, 2, 32, null);
    for (1..5) |step| try testStep(arena, &suffix, step);
    suffix.items[1].tool_result_memory = .{ .output_handle = "result-read_file-aa-bb.txt" };
    const projected = try state.view(arena, suffix.items, 0);
    try std.testing.expectEqualStrings("result-read_file-aa-bb.txt", handleIn(projected[1].content.?));
    try std.testing.expect(std.mem.startsWith(u8, projected[3].content.?, "read_file result (16 bytes) cleared"));
}

test "view skips the region compaction already cut from the request" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var suffix: std.ArrayList(ChatMessage) = .empty;
    // Each test result is 16 bytes; steps 1 and 2 alone would fill the threshold.
    var state = State.init(arena, 2, 32, null);
    for (1..5) |step| try testStep(arena, &suffix, step);

    // Compaction cut steps 1 and 2 (four messages), leaving nothing evictable.
    const same = try state.view(arena, suffix.items, 4);
    try std.testing.expectEqual(suffix.items.ptr, same.ptr);
    try std.testing.expectEqual(@as(usize, 0), state.evicted_before);

    // Two more steps refill the threshold behind the kept window: the sweep
    // starts at the request start, so steps 3 and 4 go and 5 and 6 stay.
    for (5..7) |step| try testStep(arena, &suffix, step);
    const projected = try state.view(arena, suffix.items, 4);
    try std.testing.expectEqual(@as(usize, 8), state.evicted_before);
    try std.testing.expect(std.mem.indexOf(u8, projected[5].content.?, "cleared from the request") != null);
    try std.testing.expectEqualStrings("output of step 5", projected[9].content.?);
}
