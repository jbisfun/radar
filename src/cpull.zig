//! A client of cpull's JSON API (theme docs/workspace-tools.md §4): radar
//! never writes events itself, it asks cpull, which authors them as pull's
//! identity.
const std = @import("std");
const discovery = @import("discovery");
const anchor = @import("anchor.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const not_running = "cpull isn't running (start the cpull job)";

/// cpull's `Repo`
pub const Repo = struct {
    name: []const u8,
    identity: []const u8 = "",
    path: []const u8 = "",
    branch: ?[]const u8 = null,
    url: []const u8 = "",
    issues_url: []const u8 = "",
    cloned: bool = true,
    open_issues: u64 = 0,
    open_reports: u64 = 0,
};

/// cpull's `Issue`
pub const Issue = struct {
    id: []const u8,
    repo: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    labels: []const u8 = "",
    status: []const u8 = "open",
    author: ?[]const u8 = null,
    created: []const u8 = "",
    url: []const u8 = "",
    anchor: ?anchor.Anchor = null,
};

/// cpull's `Report` (what `cpull report list --json` printed)
pub const Report = struct {
    id: []const u8,
    repo: []const u8,
    file: []const u8,
    line: u64,
    line_text: []const u8 = "",
    quote: ?[]const u8 = null,
    note: ?[]const u8 = null,
    title: []const u8 = "",
    status: []const u8 = "open",
    source: []const u8 = "",
    commit: ?[]const u8 = null,
    created: []const u8 = "",
    author: ?[]const u8 = null,
    url: []const u8 = "",

    pub fn fromIssue(i: Issue) !Report {
        const an = i.anchor orelse return error.NotAReport;
        return .{
            .id = i.id,
            .repo = i.repo,
            .file = an.file,
            .line = an.line,
            .line_text = an.line_text,
            .quote = an.quote,
            .note = if (i.description.len == 0) null else i.description,
            .title = i.title,
            .status = i.status,
            .source = an.source orelse "",
            .commit = an.commit,
            .created = i.created,
            .author = i.author,
            .url = i.url,
        };
    }

    pub fn anchorOf(r: Report) anchor.Anchor {
        return .{ .file = r.file, .line = r.line, .line_text = r.line_text, .quote = r.quote, .commit = r.commit, .source = if (r.source.len == 0) null else r.source };
    }
};

pub const NewIssue = struct {
    repo: []const u8,
    title: []const u8,
    description: []const u8,
    labels: []const u8,
    anchor: anchor.Anchor,
};

pub const Error = error{ CpullNotRunning, WrongWorkspace, CpullError, OutOfMemory };

pub const Client = struct {
    a: Allocator,
    io: Io,
    http: std.http.Client,
    /// "http://host:port"
    base: []const u8,
    root: []const u8,
    /// what went wrong in the last failed call, for the user
    message: []const u8 = "",

    /// Connects to the cpull serving `root`: `explicit` (--addr or
    /// $CPULL_ADDR), else .pull/cpull/serve.addr, else the default; fails
    /// unless its /api/health names `root`. On failure `message` says why.
    pub fn connect(io: Io, a: Allocator, root: []const u8, explicit: ?[]const u8, message: *[]const u8) Error!Client {
        message.* = not_running;
        const addr = discovery.connectAddr(io, a, root, .cpull, explicit) catch return error.OutOfMemory;
        var c: Client = .{
            .a = a,
            .io = io,
            .http = .{ .allocator = a, .io = io },
            .base = discovery.baseUrl(a, addr) catch return error.OutOfMemory,
            .root = root,
        };
        errdefer c.http.deinit();
        const health = c.send(.GET, "/api/health", null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CpullError => {
                message.* = try std.fmt.allocPrint(a, "{s} answers but has no cpull /api ({s}; an older cpull?); pass --addr", .{ addr, c.message });
                return error.WrongWorkspace;
            },
            else => return error.CpullNotRunning,
        };
        const served = if (health == .object) health.object.get("root") else null;
        if (served == null or served.? != .string) {
            message.* = try std.fmt.allocPrint(a, "{s} answers but isn't cpull; pass --addr", .{addr});
            return error.WrongWorkspace;
        }
        if (!sameDir(io, a, served.?.string, root)) {
            message.* = try std.fmt.allocPrint(a, "the cpull at {s} serves {s}, not {s}; pass --addr", .{ addr, served.?.string, root });
            return error.WrongWorkspace;
        }
        message.* = "";
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.http.deinit();
    }

    const SendError = Error || error{Unreachable};

    /// One request; the parsed JSON on a 2xx answer, else error.CpullError
    /// with cpull's `{"error"}` in `message`.
    fn send(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) SendError!std.json.Value {
        const body = try c.sendRaw(method, path, payload);
        return std.json.parseFromSliceLeaky(std.json.Value, c.a, body, .{}) catch {
            c.message = try std.fmt.allocPrint(c.a, "cpull {s} {s}: not json", .{ @tagName(method), path });
            return error.CpullError;
        };
    }

    fn sendRaw(c: *Client, method: std.http.Method, path: []const u8, payload: ?[]const u8) SendError![]const u8 {
        var out: std.Io.Writer.Allocating = .init(c.a);
        const url = try std.fmt.allocPrint(c.a, "{s}{s}", .{ c.base, path });
        const res = c.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .raw_uri = true,
            // no pooled connections: they point back at the std.http.Client,
            // which moves when connect() returns
            .keep_alive = false,
            .response_writer = &out.writer,
            .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default },
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                c.message = not_running;
                return error.Unreachable;
            },
        };
        if (res.status.class() != .success) {
            c.message = errorOf(c.a, out.written()) orelse try std.fmt.allocPrint(c.a, "cpull answered {d} {s}", .{ @intFromEnum(res.status), res.status.phrase() orelse "" });
            return error.CpullError;
        }
        return out.written();
    }

    fn call(c: *Client, comptime T: type, method: std.http.Method, path: []const u8, payload: ?[]const u8) Error!T {
        const body = c.sendRaw(method, path, payload) catch |e| switch (e) {
            error.Unreachable => return error.CpullNotRunning,
            else => |x| return x,
        };
        return std.json.parseFromSliceLeaky(T, c.a, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            c.message = try std.fmt.allocPrint(c.a, "cpull {s} {s}: unexpected answer {s}", .{ @tagName(method), path, body[0..@min(body.len, 200)] });
            return error.CpullError;
        };
    }

    pub fn repos(c: *Client) Error![]const Repo {
        return c.call([]const Repo, .GET, "/api/repos", null);
    }

    pub const Filter = struct { status: []const u8 = "open", repo: ?[]const u8 = null, file: ?[]const u8 = null };

    pub fn reports(c: *Client, f: Filter) Error![]const Report {
        var w: std.Io.Writer.Allocating = .init(c.a);
        w.writer.writeAll("/api/reports?status=") catch return error.OutOfMemory;
        encode(&w.writer, f.status) catch return error.OutOfMemory;
        inline for (.{ "repo", "file" }) |k| if (@field(f, k)) |v| {
            w.writer.writeAll("&" ++ k ++ "=") catch return error.OutOfMemory;
            encode(&w.writer, v) catch return error.OutOfMemory;
        };
        return c.call([]const Report, .GET, w.written(), null);
    }

    pub fn createIssue(c: *Client, new: NewIssue) Error!Issue {
        const body = std.json.Stringify.valueAlloc(c.a, new, .{}) catch return error.OutOfMemory;
        return c.call(Issue, .POST, "/api/issues", body);
    }

    /// `action` is "close" or "reopen"
    pub fn setStatus(c: *Client, repo: []const u8, id: []const u8, action: []const u8) Error!Issue {
        var w: std.Io.Writer.Allocating = .init(c.a);
        w.writer.writeAll("/api/issues/") catch return error.OutOfMemory;
        var it = std.mem.splitScalar(u8, if (repo.len == 0) "." else repo, '/');
        var first = true;
        while (it.next()) |seg| {
            if (!first) w.writer.writeByte('/') catch return error.OutOfMemory;
            first = false;
            encode(&w.writer, seg) catch return error.OutOfMemory;
        }
        w.writer.print("/{s}/{s}", .{ id, action }) catch return error.OutOfMemory;
        return c.call(Issue, .POST, w.written(), "{}");
    }
};

fn errorOf(a: Allocator, body: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch return null;
    if (v != .object) return null;
    const e = v.object.get("error") orelse return null;
    return if (e == .string) e.string else null;
}

fn unreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

/// Percent-encodes a url component.
pub fn encode(w: *std.Io.Writer, s: []const u8) !void {
    try std.Uri.Component.percentEncode(w, s, unreserved);
}

fn sameDir(io: Io, a: Allocator, x: []const u8, y: []const u8) bool {
    if (std.mem.eql(u8, std.mem.trimEnd(u8, x, "/"), std.mem.trimEnd(u8, y, "/"))) return true;
    const rx = Io.Dir.cwd().realPathFileAlloc(io, x, a) catch return false;
    const ry = Io.Dir.cwd().realPathFileAlloc(io, y, a) catch return false;
    return std.mem.eql(u8, rx, ry);
}
