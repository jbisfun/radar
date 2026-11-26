//! The bits of git radar needs, through the git CLI (workspace repos can be
//! linked worktrees, and radar never writes to them): HEAD, a ref's commit, a
//! file's lines at a commit and HEAD's first-parent history.
const std = @import("std");
const anchor = @import("anchor.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// `git -C repo ARGS...`'s stdout, or null when git fails or can't start.
pub fn output(io: Io, a: Allocator, repo: []const u8, args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ "git", "-C", repo }) catch return null;
    argv.appendSlice(a, args) catch return null;
    const r = std.process.run(a, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(256 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch return null;
    if (!r.term.success()) return null;
    return r.stdout;
}

fn oidOf(text: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 40) return null;
    for (t) |c| if (!std.ascii.isHex(c)) return null;
    return t;
}

/// HEAD's commit, or null (no repo, an unborn branch).
pub fn head(io: Io, a: Allocator, repo: []const u8) ?[]const u8 {
    return oidOf(output(io, a, repo, &.{ "rev-parse", "--verify", "-q", "HEAD^{commit}" }) orelse return null);
}

/// The commit `ref` (a branch, tag or oid) names, or null.
pub fn resolve(io: Io, a: Allocator, repo: []const u8, ref: []const u8) ?[]const u8 {
    if (ref.len == 0 or ref[0] == '-') return null;
    const spec = std.fmt.allocPrint(a, "{s}^{{commit}}", .{ref}) catch return null;
    return oidOf(output(io, a, repo, &.{ "rev-parse", "--verify", "-q", "--end-of-options", spec }) orelse return null);
}

pub const ReadError = error{ NotAFile, BinaryFile, OutOfMemory };

/// Every line of `path` at `commit` (a final newline ends the last line).
pub fn readLines(io: Io, a: Allocator, repo: []const u8, commit: []const u8, path: []const u8) ReadError![]const []const u8 {
    const spec = try std.fmt.allocPrint(a, "{s}:{s}", .{ commit, path });
    const text = output(io, a, repo, &.{ "cat-file", "blob", spec }) orelse return error.NotAFile;
    if (std.mem.indexOfScalar(u8, text[0..@min(text.len, 8000)], 0) != null) return error.BinaryFile;
    return anchor.splitLines(a, text);
}

pub const Commit = struct { oid: []const u8, timestamp: u64 };

/// HEAD's first-parent line, newest first, at most `max` commits.
pub fn firstParents(io: Io, a: Allocator, repo: []const u8, max: usize) ![]const Commit {
    const n = try std.fmt.allocPrint(a, "-n{d}", .{max});
    const text = output(io, a, repo, &.{ "log", "--first-parent", "--format=%H %ct", n, "HEAD" }) orelse return &.{};
    var out: std.ArrayList(Commit) = .empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        try out.append(a, .{ .oid = line[0..space], .timestamp = std.fmt.parseInt(u64, line[space + 1 ..], 10) catch continue });
    }
    return out.items;
}
