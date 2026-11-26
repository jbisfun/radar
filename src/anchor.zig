//! Anchors: where a report points (a file of a repo, a 1-based line and that
//! line's text), read from the work tree or a commit, found again after the
//! code moves (relocation) and shown as an excerpt. Ported from cpull's
//! src/report (report.zig, anchor.zig), with git reads through the git CLI.
const std = @import("std");
const git = @import("git.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// the lines shown above and below the anchored line
pub const context_lines = 3;
/// every report carries this label
pub const label = "report";
/// reports migrated from radar.db also carry this one
pub const radar_label = "radar";
pub const title_max_len = 80;
pub const label_max_len = 64;

/// The anchor of a cpull issue, as the event stores it (cpull docs/report.md):
/// quote, commit and source are left out when unset.
pub const Anchor = struct {
    file: []const u8,
    line: u64,
    line_text: []const u8 = "",
    quote: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    source: ?[]const u8 = null,

    pub fn jsonStringify(self: Anchor, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("file");
        try jw.write(self.file);
        try jw.objectField("line");
        try jw.write(self.line);
        try jw.objectField("line_text");
        try jw.write(self.line_text);
        inline for (.{ "quote", "commit", "source" }) |name| {
            if (@field(self, name)) |value| {
                try jw.objectField(name);
                try jw.write(value);
            }
        }
        try jw.endObject();
    }
};

/// The code around an anchor (cpull's report/anchor.zig Excerpt, the fields
/// of the workspace-tools contract): read at the commit it was filed against,
/// else at HEAD with the line found again by its text.
pub const Excerpt = struct {
    file: []const u8,
    /// the anchored line, 1-based, in the excerpt's revision
    line: u64,
    /// the line number recorded when the report was filed
    filed_line: u64,
    /// the 1-based number of lines[0]
    first: u64,
    lines: []const []const u8,
    /// the commit the excerpt was read at
    commit: []const u8 = "",
    /// whether that is the anchor's own commit, rather than HEAD
    at_filed_commit: bool = false,
    /// the line text no longer matches what was filed, and wasn't found nearby
    changed: bool = false,
};

/// `text` split into lines without their line endings ("\r" too); a final
/// newline ends the last line rather than starting another.
pub fn splitLines(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (it.index == null and l.len == 0) break;
        try out.append(a, std.mem.trimEnd(u8, l, "\r"));
    }
    return out.items;
}

/// A repo-relative path without "./", doubled or trailing slashes.
pub fn normalizePath(a: Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.OutsideRepo;
        try parts.append(a, part);
    }
    if (parts.items.len == 0) return error.FileNotFound;
    return std.mem.join(a, "/", parts.items);
}

/// Every line of the work-tree file `file` of the repo at `repo_path`. Its
/// real path must stay inside the repo, so symlinks can't escape it.
pub fn readWorkLines(io: Io, a: Allocator, repo_path: []const u8, file: []const u8) ![]const []const u8 {
    const cwd = Io.Dir.cwd();
    const repo_real = cwd.realPathFileAlloc(io, repo_path, a) catch return error.RepoNotCloned;
    const full = try std.fs.path.join(a, &.{ repo_path, file });
    const real = cwd.realPathFileAlloc(io, full, a) catch return error.FileNotFound;
    if (!std.mem.startsWith(u8, real, repo_real) or real.len <= repo_real.len or real[repo_real.len] != '/') return error.OutsideRepo;
    const text = cwd.readFileAlloc(io, real, a, .limited(64 * 1024 * 1024)) catch |e| switch (e) {
        error.IsDir => return error.FileNotFound,
        else => |x| return x,
    };
    return splitLines(a, text);
}

/// Line `line` (1-based) of the work-tree file.
pub fn readWorkLine(io: Io, a: Allocator, repo_path: []const u8, file: []const u8, line: u64) ![]const u8 {
    if (line == 0) return error.InvalidLineNumber;
    const lines = try readWorkLines(io, a, repo_path, file);
    if (line > lines.len) return error.NoSuchLine;
    return lines[@intCast(line - 1)];
}

/// The 1-based line holding `text` (compared without surrounding whitespace)
/// nearest `line`, or null when no line does. An empty `text` keeps `line`
/// while the file still has it.
pub fn relocate(lines: []const []const u8, line: u64, text: []const u8) ?u64 {
    const want = std.mem.trim(u8, text, " \t\r");
    if (want.len == 0) return if (line >= 1 and line <= lines.len) line else null;
    const start: usize = @intCast(@min(line -| 1, lines.len));
    var distance: usize = 0;
    while (distance <= lines.len) : (distance += 1) {
        if (start + distance < lines.len and std.mem.eql(u8, std.mem.trim(u8, lines[start + distance], " \t\r"), want)) return start + distance + 1;
        if (distance > 0 and distance <= start and std.mem.eql(u8, std.mem.trim(u8, lines[start - distance], " \t\r"), want)) return start - distance + 1;
        if (start + distance >= lines.len and distance > start) break;
    }
    return null;
}

fn window(file: []const u8, filed_line: u64, lines: []const []const u8, line: u64, commit: []const u8, at_filed_commit: bool) Excerpt {
    const index: usize = @intCast(@min(line -| 1, lines.len));
    const start = index -| context_lines;
    const end = @min(lines.len, index + context_lines + 1);
    return .{
        .file = file,
        .line = line,
        .filed_line = filed_line,
        .first = start + 1,
        .lines = lines[start..end],
        .commit = commit,
        .at_filed_commit = at_filed_commit,
    };
}

/// The excerpt for `a` in the repo at `repo_path`, or null when its file
/// can't be read at the anchor's commit or at HEAD.
pub fn excerpt(io: Io, a: Allocator, repo_path: []const u8, an: Anchor) ?Excerpt {
    // the filed commit first, since the line number refers to it
    if (an.commit) |commit| if (commit.len >= 40) {
        if (git.readLines(io, a, repo_path, commit, an.file)) |lines| {
            return window(an.file, an.line, lines, an.line, commit, true);
        } else |_| {}
    };
    const head = git.head(io, a, repo_path) orelse return null;
    const lines = git.readLines(io, a, repo_path, head, an.file) catch return null;
    // the line may have moved since: look for its text nearest the old number
    const line = relocate(lines, an.line, an.line_text);
    var result = window(an.file, an.line, lines, line orelse an.line, head, false);
    result.changed = line == null and an.line_text.len > 0;
    return result;
}

/// The commit on HEAD's first-parent line that a line filed at `timestamp`
/// referred to: the newest commit no newer than it whose `path` holds `text`
/// at `line`, looking a few commits further back when that one doesn't (the
/// line may have been filed against uncommitted work). null when none does.
pub fn commitAt(io: Io, a: Allocator, repo_path: []const u8, path: []const u8, line: u64, text: []const u8, timestamp: u64) ?[]const u8 {
    const max_older = 50;
    const commits = git.firstParents(io, a, repo_path, 20000) catch return null;
    var older: usize = 0;
    for (commits) |c| {
        if (c.timestamp > timestamp) continue;
        if (git.readLines(io, a, repo_path, c.oid, path)) |lines| {
            if (line >= 1 and line <= lines.len and std.mem.eql(u8, lines[@intCast(line - 1)], text)) return c.oid;
        } else |_| {}
        older += 1;
        if (older > max_older) return null;
    }
    return null;
}

/// The quote to keep: trimmed, and null when empty or the whole line.
pub fn cleanQuote(quote: ?[]const u8, line_text: []const u8) ?[]const u8 {
    const q = quote orelse return null;
    const trimmed = std.mem.trim(u8, q, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, std.mem.trim(u8, line_text, " \t\r"))) return null;
    return trimmed;
}

/// The title: `title`, else the note's first line (cut at title_max_len),
/// else "file:line".
pub fn deriveTitle(a: Allocator, title: ?[]const u8, note: []const u8, file: []const u8, line: u64) ![]const u8 {
    if (title) |t| if (std.mem.trim(u8, t, " \t\r\n").len != 0) return std.mem.trim(u8, t, " \t\r\n");
    const first = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, note, '\n')) |nl| note[0..nl] else note, " \t\r");
    if (first.len == 0) return a.print("{s}:{d}", .{ file, line });
    if (first.len <= title_max_len) return first;
    // cut at a utf-8 boundary, then at the last space if there is one late enough
    var end: usize = title_max_len;
    while (end > 0 and (first[end] & 0xC0) == 0x80) end -= 1;
    if (std.mem.lastIndexOfScalar(u8, first[0..end], ' ')) |space| if (space > title_max_len / 2) {
        end = space;
    };
    return a.print("{s}…", .{std.mem.trimEnd(u8, first[0..end], " ,.;:")});
}

/// `labels` (space- or comma-separated) plus `extra`, deduplicated, space-joined.
pub fn joinLabels(a: Allocator, labels: []const u8, extra: []const []const u8) ![]const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, labels, " ,");
    while (it.next()) |l| try appendUnique(a, &items, l);
    for (extra) |l| try appendUnique(a, &items, l);
    return std.mem.join(a, " ", items.items);
}

fn appendUnique(a: Allocator, items: *std.ArrayList([]const u8), value: []const u8) !void {
    for (items.items) |item| if (std.mem.eql(u8, item, value)) return;
    if (value.len > label_max_len) return error.LabelTooLong;
    try items.append(a, value);
}

// ---------------------------------------------------------------- times

/// "2026-11-18T03:14:54Z"
pub fn formatTime(a: Allocator, timestamp: u64) ![]const u8 {
    const seconds = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const year = seconds.getEpochDay().calculateYearDay();
    const month = year.calculateMonthDay();
    const day = seconds.getDaySeconds();
    return a.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ year.year, month.month.numeric(), month.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute() });
}

/// Seconds since the epoch of an RFC 3339 time ("2026-11-18T03:14:54.99Z",
/// "...+05:00"), fractions dropped.
pub fn parseTime(text: []const u8) !u64 {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return error.InvalidTime;
    const year = try std.fmt.parseInt(i64, text[0..4], 10);
    const month = try std.fmt.parseInt(u8, text[5..7], 10);
    const day = try std.fmt.parseInt(u8, text[8..10], 10);
    const hour = try std.fmt.parseInt(i64, text[11..13], 10);
    const minute = try std.fmt.parseInt(i64, text[14..16], 10);
    const second = try std.fmt.parseInt(i64, text[17..19], 10);
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidTime;
    var rest = text[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        rest = rest[i..];
    }
    var offset: i64 = 0;
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {} else if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const sign: i64 = if (rest[0] == '-') -1 else 1;
        offset = sign * ((try std.fmt.parseInt(i64, rest[1..3], 10)) * 3600 + (try std.fmt.parseInt(i64, rest[4..6], 10)) * 60);
    } else return error.InvalidTime;
    const total = daysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second - offset;
    return std.math.cast(u64, total) orelse error.InvalidTime;
}

// days since 1970-01-01 of a proleptic Gregorian date: Howard Hinnant's
// days_from_civil (https://howardhinnant.github.io/date_algorithms.html)
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// "just now", "5 minutes ago", "3 days ago", ...
pub fn relative(a: Allocator, then: u64, now: u64) ![]const u8 {
    const d = now -| then;
    const units = [_]struct { []const u8, u64 }{ .{ "year", 365 * 86400 }, .{ "month", 30 * 86400 }, .{ "day", 86400 }, .{ "hour", 3600 }, .{ "minute", 60 } };
    for (units) |u| if (d >= u[1]) {
        const n = d / u[1];
        return a.print("{d} {s}{s} ago", .{ n, u[0], if (n == 1) "" else "s" });
    };
    return "just now";
}

test parseTime {
    try std.testing.expectEqual(@as(u64, 0), try parseTime("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(u64, 1794971694), try parseTime("2026-11-18T03:14:54.992190370Z"));
    try std.testing.expectEqual(@as(u64, 1794971694), try parseTime("2026-11-17T22:14:54-05:00"));
    try std.testing.expectError(error.InvalidTime, parseTime("yesterday"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("2026-11-18T03:14:54Z", try formatTime(arena.allocator(), 1794971694));
    try std.testing.expectEqualStrings("2 days ago", try relative(arena.allocator(), 0, 2 * 86400 + 5));
}

test deriveTitle {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src/a.zig:3", try deriveTitle(a, null, "", "src/a.zig", 3));
    try std.testing.expectEqualStrings("panics", try deriveTitle(a, null, "panics\nmore", "a", 1));
    try std.testing.expectEqualStrings("T", try deriveTitle(a, "T", "note", "a", 1));
    const long = "The jobs sidebar has a fixed 260px width with pixel paddings, and Start/Stop/Restart/Unload are bordered text buttons.";
    const title = try deriveTitle(a, null, long, "a", 1);
    try std.testing.expect(title.len <= title_max_len + "…".len);
    try std.testing.expect(std.mem.endsWith(u8, title, "…"));
}

test relocate {
    const lines = [_][]const u8{ "a", "  b", "c", "b", "d" };
    try std.testing.expectEqual(@as(?u64, 2), relocate(&lines, 2, "b"));
    try std.testing.expectEqual(@as(?u64, 4), relocate(&lines, 5, "b"));
    try std.testing.expectEqual(@as(?u64, 1), relocate(&lines, 3, "a"));
    try std.testing.expectEqual(@as(?u64, null), relocate(&lines, 3, "z"));
    try std.testing.expectEqual(@as(?u64, 3), relocate(&lines, 3, ""));
}

test "lines, paths, labels and quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try splitLines(a, "a\r\nb\n\nc\n");
    try std.testing.expectEqual(4, lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("", lines[2]);
    try std.testing.expectEqual(2, (try splitLines(a, "a\nb")).len);
    try std.testing.expectEqualStrings("src/a.zig", try normalizePath(a, "./src//a.zig/"));
    try std.testing.expectError(error.OutsideRepo, normalizePath(a, "src/../../x"));
    try std.testing.expectEqualStrings("ui report", try joinLabels(a, "ui, report", &.{label}));
    try std.testing.expectEqual(@as(?[]const u8, null), cleanQuote("  x = 1; ", "\tx = 1;"));
    try std.testing.expectEqualStrings("x", cleanQuote(" x\n", "x = 1;").?);
}
