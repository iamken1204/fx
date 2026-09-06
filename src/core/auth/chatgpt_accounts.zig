//! Stored Codex accounts beside the active `chatgpt-auth.json`.
//!
//! The active session file keeps its upstream schema and stays the only
//! session the rest of fx reads. Signing in with a different account moves
//! the previous session into `chatgpt-accounts/<account_id>.json`, and
//! activating a stored account swaps the two files under the session lock.

const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const chatgpt_oauth = @import("chatgpt_oauth.zig");
const chatgpt_session = @import("chatgpt_session.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const dir_name = "chatgpt-accounts";
const file_suffix = ".json";
const max_file_bytes: usize = 64 * 1024;

pub const Stored = struct {
    account_id: []u8,
    email: ?[]u8,

    pub fn deinit(self: *Stored, alloc: Allocator) void {
        alloc.free(self.account_id);
        if (self.email) |email| alloc.free(email);
        self.* = undefined;
    }

    /// The name a user types to pick this account: the email when the token
    /// carries one, otherwise the account ID itself.
    pub fn label(self: Stored) []const u8 {
        return self.email orelse self.account_id;
    }

    fn matches(self: Stored, query: []const u8) bool {
        if (std.mem.eql(u8, self.account_id, query)) return true;
        const email = self.email orelse return false;
        return std.ascii.eqlIgnoreCase(email, query);
    }
};

pub fn freeList(alloc: Allocator, stored: []Stored) void {
    for (stored) |*entry| entry.deinit(alloc);
    alloc.free(stored);
}

/// Moves the active session into storage unless it already belongs to
/// `keep_account_id`, so a fresh sign-in never discards another account.
/// An active file that no longer loads is left for the caller to overwrite,
/// the same way upstream sign-in treated it.
pub fn stashActive(
    alloc: Allocator,
    mutation: *chatgpt_session.Mutation,
    keep_account_id: []const u8,
) !void {
    const loaded = mutation.load(alloc) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            debug_trace.logf("auth", "Codex account stash skipped unreadable active session err={s}", .{@errorName(err)});
            return;
        },
    };
    var session = loaded orelse return;
    defer session.deinit(alloc);
    if (std.mem.eql(u8, session.account_id, keep_account_id)) return;

    var dir = try io_mod.openOrCreateVerifiedPrivateDir(&mutation.fx_dir, dir_name);
    defer dir.close();
    const name = try fileName(alloc, session.account_id);
    defer alloc.free(name);
    const text = try chatgpt_session.stringify(alloc, session);
    defer secret.zeroAndFree(alloc, text);
    try io_mod.durableReplaceVerified(alloc, &dir, name, text);
}

/// Every stored account, in directory order.
pub fn list(alloc: Allocator) ![]Stored {
    var mutation = (try chatgpt_session.beginExistingMutation()) orelse return alloc.alloc(Stored, 0);
    defer mutation.deinit();
    return listInDir(alloc, &mutation.fx_dir);
}

/// Makes the stored account matching `query` (email or account ID) the
/// active session, storing the previous active session in its place.
/// Returns the activated account's label.
pub fn activate(alloc: Allocator, query: []const u8) ![]u8 {
    var mutation = (try chatgpt_session.beginExistingMutation()) orelse return error.NoSuchAccount;
    defer mutation.deinit();
    return activateInMutation(alloc, &mutation, query);
}

fn activateInMutation(
    alloc: Allocator,
    mutation: *chatgpt_session.Mutation,
    query: []const u8,
) ![]u8 {
    try mutation.requireWritable();
    const stored = try listInDir(alloc, &mutation.fx_dir);
    defer freeList(alloc, stored);
    const chosen = for (stored) |entry| {
        if (entry.matches(query)) break entry;
    } else return error.NoSuchAccount;

    const zio = io_mod.getIo();
    var dir = try mutation.fx_dir.dir.openDir(zio, dir_name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(zio);
    const name = try fileName(alloc, chosen.account_id);
    defer alloc.free(name);
    var session = (try readStored(alloc, dir, name)) orelse return error.NoSuchAccount;
    defer session.deinit(alloc);

    try stashActive(alloc, mutation, session.account_id);
    try mutation.save(alloc, session);
    dir.deleteFile(zio, name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return alloc.dupe(u8, chosen.label());
}

fn listInDir(alloc: Allocator, fx_dir: *io_mod.VerifiedDir) ![]Stored {
    const zio = io_mod.getIo();
    var dir = fx_dir.dir.openDir(zio, dir_name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return alloc.alloc(Stored, 0),
        else => return err,
    };
    defer dir.close(zio);

    var out: std.ArrayList(Stored) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(alloc);
        out.deinit(alloc);
    }
    var entries = dir.iterate();
    while (try entries.next(zio)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, file_suffix)) continue;
        var session = (try readStored(alloc, dir, entry.name)) orelse continue;
        defer session.deinit(alloc);
        const email = try chatgpt_oauth.extractAccountEmail(alloc, session.access_token);
        errdefer if (email) |value| alloc.free(value);
        const account_id = try alloc.dupe(u8, session.account_id);
        errdefer alloc.free(account_id);
        try out.append(alloc, .{ .account_id = account_id, .email = email });
    }
    return out.toOwnedSlice(alloc);
}

/// A file that no longer parses is skipped rather than blocking the others.
fn readStored(alloc: Allocator, dir: std.Io.Dir, name: []const u8) !?chatgpt_session.Session {
    const zio = io_mod.getIo();
    var file = dir.openFile(zio, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(zio);
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_file_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    return chatgpt_session.parse(alloc, bytes) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}

fn fileName(alloc: Allocator, account_id: []const u8) ![]u8 {
    return std.mem.concat(alloc, u8, &.{ account_id, file_suffix });
}

fn testMutation(dir: std.Io.Dir) !chatgpt_session.Mutation {
    var fx_dir = io_mod.VerifiedDir{ .dir = try dir.openDir(std.testing.io, ".", .{ .iterate = true }) };
    errdefer fx_dir.close();
    const lock = try io_mod.acquireTimedAdvisoryLock(&fx_dir, "chatgpt-auth.lock", 2000);
    return .{ .fx_dir = fx_dir, .lock = lock };
}

fn testSession(alloc: Allocator, account_id: []const u8) !chatgpt_session.Session {
    return .{
        .access_token = try alloc.dupe(u8, "access"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 1,
        .account_id = try alloc.dupe(u8, account_id),
    };
}

test "a different sign-in stores the previous account and activate swaps it back" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var mutation = try testMutation(tmp.dir);
    defer mutation.deinit();

    var first = try testSession(alloc, "acct_first");
    defer first.deinit(alloc);
    try mutation.save(alloc, first);

    try stashActive(alloc, &mutation, "acct_first");
    const none = try listInDir(alloc, &mutation.fx_dir);
    defer freeList(alloc, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    try stashActive(alloc, &mutation, "acct_second");
    var second = try testSession(alloc, "acct_second");
    defer second.deinit(alloc);
    try mutation.save(alloc, second);

    const stored = try listInDir(alloc, &mutation.fx_dir);
    defer freeList(alloc, stored);
    try std.testing.expectEqual(@as(usize, 1), stored.len);
    try std.testing.expectEqualStrings("acct_first", stored[0].label());

    try std.testing.expectError(error.NoSuchAccount, activateInMutation(alloc, &mutation, "acct_missing"));
    const label = try activateInMutation(alloc, &mutation, "acct_first");
    defer alloc.free(label);
    try std.testing.expectEqualStrings("acct_first", label);

    var active = (try mutation.load(alloc)).?;
    defer active.deinit(alloc);
    try std.testing.expectEqualStrings("acct_first", active.account_id);
    const swapped = try listInDir(alloc, &mutation.fx_dir);
    defer freeList(alloc, swapped);
    try std.testing.expectEqual(@as(usize, 1), swapped.len);
    try std.testing.expectEqualStrings("acct_second", swapped[0].account_id);
}
