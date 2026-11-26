//! What radar does with reports, shared by the CLI, the web server and MCP:
//! file one (building its anchor), list them with relocation, find, close,
//! reopen, show with an excerpt, and migrate the old radar.db's export. Every
//! write goes through cpull's API (cpull.zig).
const std = @import("std");
const anchor = @import("anchor.zig");
const cpull = @import("cpull.zig");
const git = @import("git.zig");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// cpull's Report plus where its line is now in the work tree.
pub const RadarReport = struct {
    id: []const u8,
    repo: []const u8,
    file: []const u8,
    line: u64,
    line_text: []const u8,
    quote: ?[]const u8,
    note: ?[]const u8,
    title: []const u8,
    status: []const u8,
    source: []const u8,
    commit: ?[]const u8,
    created: []const u8,
    author: ?[]const u8,
    url: []const u8,
    /// the line holding line_text nearest `line` in the work tree's file, or
    /// null when it's gone
    current_line: ?u64,
    /// current_line != line
    moved: bool,
    /// the text no longer appears in the file
    changed: bool,

    pub fn short(r: RadarReport) []const u8 {
        return r.id[0..@min(r.id.len, 8)];
    }

    pub fn closed(r: RadarReport) bool {
        return std.mem.eql(u8, r.status, "closed");
    }
};

/// A RadarReport plus its excerpt (GET /api/reports/<id>, `radar show --json`).
pub const Detail = struct {
    report: RadarReport,
    excerpt: ?anchor.Excerpt,

    pub fn jsonStringify(self: Detail, jw: anytype) !void {
        try jw.beginObject();
        inline for (@typeInfo(RadarReport).@"struct".field_names) |name| {
            try jw.objectField(name);
            try jw.write(@field(self.report, name));
        }
        try jw.objectField("excerpt");
        try jw.write(self.excerpt);
        try jw.endObject();
    }
};

pub const New = struct {
    repo: []const u8,
    file: []const u8,
    line: u64,
    quote: ?[]const u8 = null,
    note: ?[]const u8 = null,
    title: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    source: ?[]const u8 = null,
    /// read the line at this commit/branch/tag instead of the work tree
    ref: ?[]const u8 = null,
};

pub const Relocated = struct { line: ?u64, changed: bool };

pub const Ctx = struct {
    io: Io,
    a: Allocator,
    root: []const u8,
    client: *cpull.Client,
    repo_list: ?[]const cpull.Repo = null,
    files: std.StringHashMapUnmanaged(?[]const []const u8) = .empty,

    pub fn repos(ctx: *Ctx) ![]const cpull.Repo {
        if (ctx.repo_list) |l| return l;
        ctx.repo_list = try ctx.client.repos();
        return ctx.repo_list.?;
    }

    fn abs(ctx: *Ctx, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) return path;
        return std.fs.path.join(ctx.a, &.{ ctx.root, path });
    }

    fn pathOf(ctx: *Ctx, r: cpull.Repo) ![]const u8 {
        return ctx.abs(if (r.path.len > 0) r.path else r.name);
    }

    /// The work tree of the repo `name` names: a pullfile repo, or "." (also
    /// "" or "workspace") for the workspace's events repo.
    pub fn repoPath(ctx: *Ctx, name_in: []const u8) ![]const u8 {
        const name = std.mem.trimEnd(u8, name_in, "/");
        const known = try ctx.repos();
        const events = name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "workspace");
        if (!events) {
            for (known) |r| if (std.mem.eql(u8, r.name, name)) return ctx.pathOf(r);
            return error.RepoNotFound;
        }
        for (known) |r| if (r.name.len == 0 or std.mem.eql(u8, r.name, ".")) return ctx.pathOf(r);
        if (workspace.eventsRepo(ctx.io, ctx.a, ctx.root)) |ev| {
            for (known) |r| if (std.mem.eql(u8, r.name, ev)) return ctx.pathOf(r);
            return ctx.abs(ev);
        }
        return ctx.root;
    }

    /// The work-tree file's lines (cached per call), null when unreadable.
    fn workLines(ctx: *Ctx, repo: []const u8, rel: []const u8) ?[]const []const u8 {
        const key = std.fmt.allocPrint(ctx.a, "{s}\x00{s}", .{ repo, rel }) catch return null;
        if (ctx.files.get(key)) |v| return v;
        const lines: ?[]const []const u8 = blk: {
            const path = ctx.repoPath(repo) catch break :blk null;
            break :blk anchor.readWorkLines(ctx.io, ctx.a, path, rel) catch null;
        };
        ctx.files.put(ctx.a, key, lines) catch {};
        return lines;
    }

    pub fn relocated(ctx: *Ctx, repo: []const u8, rel: []const u8, line: u64, line_text: []const u8) Relocated {
        const lines = ctx.workLines(repo, rel) orelse return .{ .line = null, .changed = true };
        const found = anchor.relocate(lines, line, line_text);
        return .{ .line = found, .changed = found == null };
    }

    pub fn toRadar(ctx: *Ctx, r: cpull.Report) RadarReport {
        const at = ctx.relocated(r.repo, r.file, r.line, r.line_text);
        return .{
            .id = r.id,
            .repo = r.repo,
            .file = r.file,
            .line = r.line,
            .line_text = r.line_text,
            .quote = r.quote,
            .note = r.note,
            .title = r.title,
            .status = r.status,
            .source = r.source,
            .commit = r.commit,
            .created = r.created,
            .author = r.author,
            .url = r.url,
            .current_line = at.line,
            .moved = if (at.line) |l| l != r.line else false,
            .changed = at.changed,
        };
    }

    pub fn list(ctx: *Ctx, filter: cpull.Client.Filter) ![]RadarReport {
        const found = try ctx.client.reports(filter);
        const out = try ctx.a.alloc(RadarReport, found.len);
        for (found, out) |r, *o| o.* = ctx.toRadar(r);
        return out;
    }

    /// The report whose id starts with `prefix` ("#" allowed), open or closed.
    pub fn find(ctx: *Ctx, prefix: []const u8) !cpull.Report {
        const id = std.mem.trim(u8, std.mem.trimStart(u8, std.mem.trim(u8, prefix, " "), "#"), " ");
        if (id.len == 0) return error.ReportNotFound;
        var found: ?cpull.Report = null;
        for (try ctx.client.reports(.{ .status = "all" })) |r| {
            if (!std.mem.startsWith(u8, r.id, id)) continue;
            if (found) |f| if (!std.mem.eql(u8, f.id, r.id)) return error.AmbiguousId;
            found = r;
        }
        return found orelse error.ReportNotFound;
    }

    pub fn show(ctx: *Ctx, prefix: []const u8) !Detail {
        const r = try ctx.find(prefix);
        const ex: ?anchor.Excerpt = if (ctx.repoPath(r.repo)) |path| anchor.excerpt(ctx.io, ctx.a, path, r.anchorOf()) else |_| null;
        return .{ .report = ctx.toRadar(r), .excerpt = ex };
    }

    /// close (`closed` true) or reopen a report
    pub fn setStatus(ctx: *Ctx, prefix: []const u8, closed: bool) !RadarReport {
        const r = try ctx.find(prefix);
        const issue = try ctx.client.setStatus(r.repo, r.id, if (closed) "close" else "reopen");
        var updated = r;
        updated.status = if (issue.status.len > 0) issue.status else if (closed) "closed" else "open";
        return ctx.toRadar(updated);
    }

    /// Files a report: builds the anchor (the line's text from the work tree,
    /// or at `ref`; the commit when HEAD has that text there) and asks cpull
    /// to store it as an issue.
    pub fn file(ctx: *Ctx, new: New) !RadarReport {
        const a = ctx.a;
        if (new.line == 0) return error.InvalidLineNumber;
        const repo_name = blk: {
            const n = std.mem.trimEnd(u8, std.mem.trim(u8, new.repo, " "), "/");
            break :blk if (n.len == 0 or std.mem.eql(u8, n, "workspace")) "." else n;
        };
        const path = try ctx.repoPath(repo_name);
        const file_path = try anchor.normalizePath(a, new.file);
        var line_text: []const u8 = undefined;
        var commit: ?[]const u8 = null;
        if (new.ref) |ref| if (ref.len > 0) {
            const oid = git.resolve(ctx.io, a, path, ref) orelse return error.RefNotFound;
            const lines = git.readLines(ctx.io, a, path, oid, file_path) catch |e| switch (e) {
                error.NotAFile => return error.FileNotFound,
                else => |x| return x,
            };
            if (new.line > lines.len) return error.NoSuchLine;
            line_text = lines[@intCast(new.line - 1)];
            commit = oid;
        };
        if (commit == null) {
            line_text = try anchor.readWorkLine(ctx.io, a, path, file_path, new.line);
            // HEAD's commit, when its version of the file has the same text there
            if (git.head(ctx.io, a, path)) |head| {
                if (git.readLines(ctx.io, a, path, head, file_path)) |lines| {
                    if (new.line <= lines.len and std.mem.eql(u8, lines[@intCast(new.line - 1)], line_text)) commit = head;
                } else |_| {}
            }
        }
        const note = std.mem.trim(u8, new.note orelse "", " \t\r\n");
        const source = if (new.source) |s| (if (s.len > 0) s else "cli") else "cli";
        const issue = try ctx.client.createIssue(.{
            .repo = repo_name,
            .title = try anchor.deriveTitle(a, new.title, note, file_path, new.line),
            .description = note,
            .labels = try anchor.joinLabels(a, new.labels orelse "", &.{anchor.label}),
            .anchor = .{
                .file = file_path,
                .line = new.line,
                .line_text = line_text,
                .quote = anchor.cleanQuote(new.quote, line_text),
                .commit = commit,
                .source = source,
            },
        });
        var report = cpull.Report.fromIssue(issue) catch return error.CpullDroppedAnchor;
        if (report.repo.len == 0) report.repo = repo_name;
        return ctx.toRadar(report);
    }

    /// One report of the old Rust radar's `radar list --all --json`.
    const OldReport = struct {
        number: u64,
        repo: []const u8,
        file: []const u8,
        line: u64,
        line_text: []const u8,
        quote: ?[]const u8 = null,
        note: ?[]const u8 = null,
        status: []const u8 = "open",
        source: ?[]const u8 = null,
        created: []const u8 = "",
    };

    /// Files every report of an old radar.db export (`-` = stdin) as a cpull
    /// report labelled `radar`, keeping its status, note, quote and source,
    /// with the commit found by walking the repo's history back to its filing
    /// time. A report already filed (same repo, file, line, text and note) is
    /// skipped, so this can run again.
    pub fn migrate(ctx: *Ctx, path: []const u8, out: *std.Io.Writer, err: *std.Io.Writer) !void {
        const a = ctx.a;
        const text = if (std.mem.eql(u8, path, "-")) blk: {
            var buffer: [4096]u8 = undefined;
            var reader = Io.File.stdin().reader(ctx.io, &buffer);
            break :blk try reader.interface.allocRemaining(a, .limited(256 * 1024 * 1024));
        } else try Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(256 * 1024 * 1024));
        const old = try std.json.parseFromSliceLeaky([]const OldReport, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        var present: std.StringHashMapUnmanaged(void) = .empty;
        for (try ctx.client.reports(.{ .status = "all" })) |r| try present.put(a, try migrateKey(a, r.repo, r.file, r.line, r.line_text, r.note orelse ""), {});

        var counts = struct { open: usize = 0, closed: usize = 0, present: usize = 0, unknown: usize = 0 }{};
        for (old) |r| {
            const repo_path = ctx.repoPath(r.repo) catch {
                try err.print("radar #{d}: no repo `{s}` in the pullfile; skipped\n", .{ r.number, r.repo });
                counts.unknown += 1;
                continue;
            };
            const note = std.mem.trim(u8, r.note orelse "", " \t\r\n");
            if (present.contains(try migrateKey(a, r.repo, r.file, r.line, r.line_text, note))) {
                counts.present += 1;
                continue;
            }
            const timestamp = anchor.parseTime(r.created) catch @as(u64, @intCast(Io.Timestamp.now(ctx.io, .real).toSeconds()));
            const issue = try ctx.client.createIssue(.{
                .repo = r.repo,
                .title = try anchor.deriveTitle(a, null, note, r.file, r.line),
                .description = note,
                .labels = try anchor.joinLabels(a, "", &.{ anchor.label, anchor.radar_label }),
                .anchor = .{
                    .file = r.file,
                    .line = r.line,
                    .line_text = r.line_text,
                    .quote = r.quote,
                    .commit = anchor.commitAt(ctx.io, a, repo_path, r.file, r.line, r.line_text, timestamp),
                    .source = r.source orelse "cli",
                },
            });
            const closed = std.mem.eql(u8, r.status, "closed");
            if (closed) _ = try ctx.client.setStatus(if (issue.repo.len > 0) issue.repo else r.repo, issue.id, "close");
            if (closed) counts.closed += 1 else counts.open += 1;
            try out.print("radar #{d} -> {s} {s}/{s}:{d}{s}\n", .{ r.number, issue.id[0..@min(issue.id.len, 8)], r.repo, r.file, r.line, if (closed) " (closed)" else "" });
        }
        try out.print("migrated {d} of {d} radar reports ({d} open, {d} closed); {d} already present, {d} in unknown repos\n", .{ counts.open + counts.closed, old.len, counts.open, counts.closed, counts.present, counts.unknown });
    }
};

fn migrateKey(a: Allocator, repo: []const u8, file: []const u8, line: u64, line_text: []const u8, note: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}\x00{s}\x00{d}\x00{s}\x00{s}", .{ std.mem.trimEnd(u8, repo, "/"), file, line, line_text, std.mem.trim(u8, note, " \t\r\n") });
}

/// A user-facing message for an error of these operations.
pub fn describe(e: anyerror, client: ?*const cpull.Client) []const u8 {
    return switch (e) {
        error.CpullNotRunning => cpull.not_running,
        error.WrongWorkspace, error.CpullError => if (client) |c| c.message else @errorName(e),
        error.RepoNotFound => "no such repo in the pullfile (use \".\" for the workspace's events repo)",
        error.RepoNotCloned => "the repo isn't cloned",
        error.FileNotFound => "no such file",
        error.OutsideRepo => "the file is outside the repo",
        error.NoSuchLine => "the file has no such line",
        error.InvalidLineNumber => "lines start at 1",
        error.RefNotFound => "no such commit, branch or tag",
        error.BinaryFile => "that's a binary file",
        error.LabelTooLong => "a label is longer than 64 characters",
        error.ReportNotFound => "no report has that id",
        error.AmbiguousId => "that id prefix matches more than one report",
        error.CpullDroppedAnchor => "cpull filed the issue without its anchor (an older cpull?)",
        else => @errorName(e),
    };
}
