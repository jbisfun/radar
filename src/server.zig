//! `radar serve`: radar's JSON API (theme docs/workspace-tools.md §7) and its
//! small web UI (a list of reports, a report with its code, a form to file
//! one), on the shared theme. Every request talks to cpull's API.
const std = @import("std");
const theme = @import("theme");
const discovery = @import("discovery");
const highlight = @import("highlight");
const anchor = @import("anchor.zig");
const cpull = @import("cpull.zig");
const reports = @import("reports.zig");
const cli = @import("cli.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Request = std.http.Server.Request;
const log = std.log.scoped(.radar);

pub const Options = struct {
    root: []const u8,
    listen: []const u8,
    cpull_addr: ?[]const u8 = null,
    log: *std.Io.Writer,
};

pub const App = struct {
    io: Io,
    gpa: Allocator,
    root: []const u8,
    cpull_addr: ?[]const u8,
};

pub const templates = [_]theme.Template{
    .{ .name = "radar/index.html", .source = @embedFile("templates/index.html") },
    .{ .name = "radar/report.html", .source = @embedFile("templates/report.html") },
    .{ .name = "radar/new.html", .source = @embedFile("templates/new.html") },
    .{ .name = "radar/macros.html", .source = @embedFile("templates/macros.html") },
};

const css = @embedFile("radar.css") ++ "\n" ++ highlight.css;

/// Binds `listen`, announces it in .pull/radar/serve.addr and serves until
/// killed.
pub fn serve(io: Io, gpa: Allocator, opts: Options) !void {
    const addr = Io.net.IpAddress.parseLiteral(opts.listen) catch return error.InvalidAddress;
    var srv = try addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    var buf: [64]u8 = undefined;
    const bound = try std.fmt.bufPrint(&buf, "{f}", .{srv.socket.address});
    var serving = try discovery.announce(io, gpa, opts.root, .radar, bound);
    defer serving.release(io, gpa);
    try opts.log.print("radar: serving {s} at http://{s}/\n", .{ opts.root, bound });
    try opts.log.flush();
    var app: App = .{ .io = io, .gpa = std.heap.smp_allocator, .root = opts.root, .cpull_addr = opts.cpull_addr };
    acceptLoop(&app, &srv);
}

pub fn acceptLoop(app: *App, srv: *Io.net.Server) void {
    while (true) {
        const stream = srv.accept(app.io) catch |e| switch (e) {
            error.SocketNotListening => return,
            else => continue,
        };
        const t = std.Thread.spawn(.{}, connection, .{ app, stream }) catch {
            stream.close(app.io);
            continue;
        };
        t.detach();
    }
}

fn connection(app: *App, stream: Io.net.Stream) void {
    defer stream.close(app.io);
    var recv: [16 * 1024]u8 = undefined;
    var send: [16 * 1024]u8 = undefined;
    var br = stream.reader(app.io, &recv);
    var bw = stream.writer(app.io, &send);
    var http = std.http.Server.init(&br.interface, &bw.interface);
    while (http.reader.state == .ready) {
        var request = http.receiveHead() catch return;
        handle(app, &request) catch return;
    }
}

const Req = struct {
    app: *App,
    io: Io,
    a: Allocator,
    request: *Request,
    query: []const u8,
    client: ?cpull.Client = null,
    why: []const u8 = "",

    fn param(r: *Req, key: []const u8) ?[]const u8 {
        return formValue(r.a, r.query, key);
    }

    fn json(r: *Req, status: std.http.Status, value: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(r.a, value, .{});
        try r.request.respond(bytes, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    }

    fn fail(r: *Req, status: std.http.Status, msg: []const u8) !void {
        try r.json(status, .{ .@"error" = msg });
    }

    fn html(r: *Req, status: std.http.Status, content: []const u8) !void {
        try r.request.respond(content, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }} });
    }

    fn redirect(r: *Req, location: []const u8) !void {
        try r.request.respond("", .{ .status = .see_other, .extra_headers = &.{.{ .name = "location", .value = location }} });
    }

    fn body(r: *Req) ![]const u8 {
        var buf: [4096]u8 = undefined;
        const reader = r.request.readerExpectContinue(&buf) catch return error.BadRequest;
        return reader.allocRemaining(r.a, .limited(1 << 20)) catch return error.BadRequest;
    }

    /// A reports.Ctx over a fresh cpull connection, or null with `why` set.
    fn ctx(r: *Req) ?reports.Ctx {
        if (r.client == null) {
            r.client = cpull.Client.connect(r.io, r.a, r.app.root, r.app.cpull_addr, &r.why) catch return null;
        }
        return .{ .io = r.io, .a = r.a, .root = r.app.root, .client = &r.client.? };
    }

    fn deinit(r: *Req) void {
        if (r.client) |*c| c.deinit();
    }
};

fn handle(app: *App, request: *Request) !void {
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const target = try a.dupe(u8, request.head.target);
    const q = std.mem.indexOfScalar(u8, target, '?');
    const raw_path = target[0 .. q orelse target.len];
    const path = decode(a, raw_path);
    var r: Req = .{ .app = app, .io = app.io, .a = a, .request = request, .query = if (q) |i| target[i + 1 ..] else "" };
    defer r.deinit();
    route(&r, if (path.len > 1) std.mem.trimEnd(u8, path, "/") else path) catch |e| switch (e) {
        error.WriteFailed, error.HttpExpectationFailed => return e,
        else => {
            log.err("{s} {s}: {t}", .{ @tagName(request.head.method), path, e });
            r.fail(.internal_server_error, @errorName(e)) catch {};
        },
    };
}

fn route(r: *Req, path: []const u8) !void {
    const method = r.request.head.method;
    if (method == .POST) {
        if (!isSameOrigin(r.request)) return r.fail(.forbidden, "cross-origin request");
        if (std.mem.eql(u8, path, "/api/reports")) return apiFile(r);
        if (std.mem.eql(u8, path, "/api/relocate")) return apiRelocate(r);
        if (idRoute(path, "/api/reports/", "/close")) |id| return apiStatus(r, id, true);
        if (idRoute(path, "/api/reports/", "/reopen")) |id| return apiStatus(r, id, false);
        if (std.mem.eql(u8, path, "/reports")) return formFile(r);
        if (idRoute(path, "/reports/", "/close")) |id| return formStatus(r, id, true);
        if (idRoute(path, "/reports/", "/reopen")) |id| return formStatus(r, id, false);
        return r.fail(.not_found, "not found");
    }
    if (method != .GET and method != .HEAD) return r.fail(.method_not_allowed, "method not allowed");
    if (std.mem.eql(u8, path, "/api/health")) return r.json(.ok, .{ .ok = true, .tool = "radar", .root = r.app.root, .version = cli.version });
    if (std.mem.eql(u8, path, "/api/reports")) return apiList(r);
    if (std.mem.startsWith(u8, path, "/api/reports/")) return apiShow(r, path["/api/reports/".len..]);
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "")) return indexPage(r);
    if (std.mem.eql(u8, path, "/new")) return newPage(r, null, .{});
    if (std.mem.startsWith(u8, path, "/reports/")) return reportPage(r, path["/reports/".len..]);
    if (std.mem.eql(u8, path, "/assets/radar.css"))
        return r.request.respond(css, .{ .extra_headers = &.{ .{ .name = "content-type", .value = "text/css; charset=utf-8" }, .{ .name = "cache-control", .value = "max-age=300" } } });
    if (path.len > 1) for (theme.assets) |asset| if (std.mem.eql(u8, path[1..], asset.path))
        return r.request.respond(asset.body, .{ .extra_headers = &.{ .{ .name = "content-type", .value = asset.content_type }, .{ .name = "cache-control", .value = "max-age=300" } } });
    if (std.mem.startsWith(u8, path, "/api/")) return r.fail(.not_found, "not found");
    return errorPage(r, .not_found, "Not found", "There is no page here.");
}

/// `<prefix><id><suffix>` -> id
fn idRoute(path: []const u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, suffix)) return null;
    if (path.len <= prefix.len + suffix.len) return null;
    const id = path[prefix.len .. path.len - suffix.len];
    if (std.mem.indexOfScalar(u8, id, '/') != null) return null;
    return id;
}

fn isSameOrigin(request: *Request) bool {
    const origin = header(request, "origin") orelse return true;
    const host = header(request, "host") orelse return false;
    const scheme_end = std.mem.indexOf(u8, origin, "://") orelse return false;
    return std.ascii.eqlIgnoreCase(origin[scheme_end + 3 ..], host);
}

fn header(request: *Request, name: []const u8) ?[]const u8 {
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

/// Percent-decode a url component ('+' is a space in query strings and forms).
fn decode(a: Allocator, s: []const u8) []const u8 {
    const buf = a.dupe(u8, s) catch return s;
    for (buf) |*c| if (c.* == '+') {
        c.* = ' ';
    };
    return std.Uri.percentDecodeInPlace(buf);
}

/// The value of `key` in an application/x-www-form-urlencoded string.
fn formValue(a: Allocator, form: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, form, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse kv.len;
        if (!std.mem.eql(u8, decode(a, kv[0..eq]), key)) continue;
        return decode(a, if (eq < kv.len) kv[eq + 1 ..] else "");
    }
    return null;
}

/// The HTTP status for an error of a reports operation.
fn statusOf(e: anyerror) std.http.Status {
    return switch (e) {
        error.CpullNotRunning => .service_unavailable,
        error.WrongWorkspace, error.CpullError, error.CpullDroppedAnchor => .bad_gateway,
        error.ReportNotFound => .not_found,
        error.OutOfMemory => .internal_server_error,
        else => .bad_request,
    };
}

fn failWith(r: *Req, e: anyerror) !void {
    if (e == error.WriteFailed) return e;
    return r.fail(statusOf(e), reports.describe(e, if (r.client) |*c| c else null));
}

// ---------------------------------------------------------------- the API

fn apiList(r: *Req) !void {
    var ctx = r.ctx() orelse return r.fail(.service_unavailable, r.why);
    const status = r.param("status") orelse "open";
    if (!isStatus(status)) return r.fail(.bad_request, "status is open, closed or all");
    const list = ctx.list(.{ .status = status, .repo = nonEmpty(r.param("repo")), .file = nonEmpty(r.param("file")) }) catch |e| return failWith(r, e);
    return r.json(.ok, list);
}

fn isStatus(s: []const u8) bool {
    return std.mem.eql(u8, s, "open") or std.mem.eql(u8, s, "closed") or std.mem.eql(u8, s, "all");
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

fn apiShow(r: *Req, id: []const u8) !void {
    if (id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null) return r.fail(.not_found, "not found");
    var ctx = r.ctx() orelse return r.fail(.service_unavailable, r.why);
    const d = ctx.show(id) catch |e| return failWith(r, e);
    return r.json(.ok, d);
}

fn apiFile(r: *Req) !void {
    const text = try r.body();
    const new = std.json.parseFromSliceLeaky(reports.New, r.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return r.fail(.bad_request, "want {repo, file, line, quote?, note?, title?, labels?, source?, ref?}");
    var ctx = r.ctx() orelse return r.fail(.service_unavailable, r.why);
    const filed = ctx.file(new) catch |e| return failWith(r, e);
    return r.json(.created, filed);
}

fn apiStatus(r: *Req, id: []const u8, closed: bool) !void {
    _ = r.body() catch {};
    var ctx = r.ctx() orelse return r.fail(.service_unavailable, r.why);
    const done = ctx.setStatus(id, closed) catch |e| return failWith(r, e);
    return r.json(.ok, done);
}

fn apiRelocate(r: *Req) !void {
    const Body = struct { repo: []const u8, file: []const u8, line: u64, line_text: []const u8 };
    const b = std.json.parseFromSliceLeaky(Body, r.a, try r.body(), .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return r.fail(.bad_request, "want {repo, file, line, line_text}");
    var ctx = r.ctx() orelse return r.fail(.service_unavailable, r.why);
    _ = ctx.repoPath(b.repo) catch |e| return failWith(r, e);
    const file = anchor.normalizePath(r.a, b.file) catch |e| return failWith(r, e);
    return r.json(.ok, ctx.relocated(b.repo, file, b.line, b.line_text));
}

// ---------------------------------------------------------------- pages

const Row = struct {
    id: []const u8,
    short: []const u8,
    title: []const u8,
    href: []const u8,
    repo: []const u8,
    location: []const u8,
    /// "" when the line is where it was filed
    now: []const u8,
    changed: bool,
    closed: bool,
    created: theme.Time,
    source: []const u8,
    line_text: []const u8,
};

fn time(a: Allocator, io: Io, created: []const u8) !theme.Time {
    const then = anchor.parseTime(created) catch return .{ .relative = created };
    const now: u64 = @intCast(Io.Timestamp.now(io, .real).toSeconds());
    return .{ .relative = try anchor.relative(a, then, now), .exact = created, .utc = created };
}

fn rowOf(r: *Req, rep: reports.RadarReport) !Row {
    return .{
        .id = rep.id,
        .short = rep.short(),
        .title = rep.title,
        .href = try std.fmt.allocPrint(r.a, "/reports/{s}", .{rep.id}),
        .repo = rep.repo,
        .location = try std.fmt.allocPrint(r.a, "{s}/{s}:{d}", .{ rep.repo, rep.file, rep.line }),
        .now = if (!rep.changed and rep.moved) try std.fmt.allocPrint(r.a, "now line {d}", .{rep.current_line.?}) else "",
        .changed = rep.changed,
        .closed = rep.closed(),
        .created = try time(r.a, r.io, rep.created),
        .source = rep.source,
        .line_text = std.mem.trim(u8, rep.line_text, " \t\r"),
    };
}

const Nav = enum { none, reports, new };

fn layout(r: *Req, nav: Nav, title: []const u8, crumbs: []const theme.Link, tasks: []const theme.Link, groups: []const theme.Group, flashes: []const theme.Flash) !theme.Layout {
    return .{
        .title = title,
        .site = "Radar",
        .tools = theme.workspaceTools(r.io, r.a, r.app.root, .radar, &.{}) catch &.{},
        .nav = try r.a.dupe(theme.Link, &.{ .{ .label = "Reports", .href = "/", .active = nav == .reports }, .{ .label = "File a report", .href = "/new", .active = nav == .new } }),
        .crumbs = crumbs,
        .tasks = tasks,
        .groups = groups,
        .flashes = flashes,
        .stylesheets = &.{"/assets/radar.css"},
        .footer = try r.a.dupe(theme.Link, &.{ .{ .label = "radar " ++ cli.version }, .{ .label = r.app.root } }),
    };
}

fn page(r: *Req, status: std.http.Status, name: []const u8, context: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(r.a);
    try theme.render(&templates, r.app.gpa, r.a, name, context, &out.writer);
    return r.html(status, out.written());
}

/// The forge's base url, for links to report issues ("" when cpull isn't running).
fn forgeBase(r: *Req) []const u8 {
    const addr = (discovery.read(r.io, r.a, r.app.root, .cpull) catch null) orelse return if (r.client) |c| c.base else "";
    return discovery.baseUrl(r.a, addr) catch "";
}

fn indexPage(r: *Req) !void {
    const a = r.a;
    const status_in = r.param("status") orelse "open";
    const status = if (isStatus(status_in)) status_in else "open";
    const repo = nonEmpty(r.param("repo"));
    var flashes: std.ArrayList(theme.Flash) = .empty;
    var all: []const reports.RadarReport = &.{};
    if (r.ctx()) |c| {
        var ctx = c;
        all = ctx.list(.{ .status = "all" }) catch |e| blk: {
            try flashes.append(a, .{ .text = reports.describe(e, &r.client.?), .kind = "danger" });
            break :blk &.{};
        };
    } else try flashes.append(a, .{ .text = r.why, .kind = "warning" });

    // counts per status and the repos with reports (open count as detail)
    var counts = [3]usize{ 0, 0, 0 };
    var repo_names: std.ArrayList([]const u8) = .empty;
    var repo_open: std.ArrayList(usize) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    for (all) |rep| {
        const closed = rep.closed();
        const i = for (repo_names.items, 0..) |n, j| {
            if (std.mem.eql(u8, n, rep.repo)) break j;
        } else blk: {
            try repo_names.append(a, rep.repo);
            try repo_open.append(a, 0);
            break :blk repo_names.items.len - 1;
        };
        if (!closed) repo_open.items[i] += 1;
        const in_repo = if (repo) |want| std.mem.eql(u8, rep.repo, want) else true;
        if (!in_repo) continue;
        counts[if (closed) 1 else 0] += 1;
        counts[2] += 1;
        const shown = std.mem.eql(u8, status, "all") or (std.mem.eql(u8, status, "closed") == closed);
        if (shown) try rows.append(a, try rowOf(r, rep));
    }
    // newest first on the page
    std.mem.reverse(Row, rows.items);

    const repo_q = if (repo) |n| try std.fmt.allocPrint(a, "&repo={s}", .{try urlEncode(a, n)}) else "";
    const statuses = [_][]const u8{ "open", "closed", "all" };
    var tabs: [3]theme.Link = undefined;
    for (statuses, &tabs, counts) |s, *t, n| t.* = .{
        .label = if (std.mem.eql(u8, s, "open")) "Open" else if (std.mem.eql(u8, s, "closed")) "Closed" else "All",
        .href = try std.fmt.allocPrint(a, "/?status={s}{s}", .{ s, repo_q }),
        .active = std.mem.eql(u8, s, status),
        .count = n,
    };
    var repo_rows: std.ArrayList(theme.Row) = .empty;
    for (repo_names.items, repo_open.items) |n, open| try repo_rows.append(a, .{
        .label = n,
        .href = try std.fmt.allocPrint(a, "/?status={s}&repo={s}", .{ status, try urlEncode(a, n) }),
        .detail = if (open > 0) try std.fmt.allocPrint(a, "{d}", .{open}) else "",
        .avatar = try theme.avatar(a, n, "cpull-identicon-sm"),
        .active = if (repo) |want| std.mem.eql(u8, want, n) else false,
        .title = try std.fmt.allocPrint(a, "{d} open", .{open}),
    });
    const crumbs: []const theme.Link = if (repo) |n|
        try a.dupe(theme.Link, &.{ .{ .label = "Radar", .href = "/" }, .{ .label = n } })
    else
        &.{.{ .label = "Radar", .href = "/" }};
    const tasks = [_]theme.Link{
        .{ .label = "Open reports", .href = "/?status=open", .icon = "flag", .active = repo == null and std.mem.eql(u8, status, "open") },
        .{ .label = "Closed reports", .href = "/?status=closed", .icon = "check2-circle", .active = repo == null and std.mem.eql(u8, status, "closed") },
        .{ .label = "File a report", .href = "/new", .icon = "plus-circle" },
    };
    const groups = [_]theme.Group{.{ .title = "Repos", .rows = repo_rows.items, .empty = "No reports yet." }};
    return page(r, .ok, "radar/index.html", .{
        .layout = try layout(r, .reports, if (repo) |n| try std.fmt.allocPrint(a, "{s} · Radar", .{n}) else "Radar", crumbs, &tasks, &groups, flashes.items),
        .page = .{
            .heading = if (repo) |n| try std.fmt.allocPrint(a, "Reports in {s}", .{n}) else "Reports",
            .tabs = &tabs,
            .rows = rows.items,
            .status = status,
            .empty = if (std.mem.eql(u8, status, "all")) "No reports." else try std.fmt.allocPrint(a, "No {s} reports.", .{status}),
            .connected = r.client != null,
            .new_href = if (repo) |n| try std.fmt.allocPrint(a, "/new?repo={s}", .{try urlEncode(a, n)}) else "/new",
        },
    });
}

fn urlEncode(a: Allocator, s: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try cpull.encode(&w.writer, s);
    return w.written();
}

const CodeLine = struct { number: u64, html: theme.vin.Str, hit: bool };

/// `lines` highlighted one by one for `file`'s language (an excerpt is a few
/// lines, so a construct spanning lines may lose its colour at the edges).
fn highlightLines(a: Allocator, file: []const u8, lines: []const []const u8, first: u64, hit: u64) ![]const CodeLine {
    const base = std.fs.path.basename(file);
    const lang = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[dot + 1 ..] else base;
    const out = try a.alloc(CodeLine, lines.len);
    for (lines, out, 0..) |text, *o, i| {
        var buf: std.ArrayList(u8) = .empty;
        highlight.write(a, &buf, lang, text) catch {
            buf.clearRetainingCapacity();
            try highlight.escape(a, &buf, text);
        };
        o.* = .{ .number = first + i, .html = theme.markup(buf.items), .hit = first + i == hit };
    }
    return out;
}

fn reportPage(r: *Req, id: []const u8) !void {
    const a = r.a;
    if (id.len == 0 or std.mem.indexOfScalar(u8, id, '/') != null) return errorPage(r, .not_found, "Not found", "There is no page here.");
    var ctx = r.ctx() orelse return errorPage(r, .service_unavailable, "cpull isn't running", r.why);
    const d = ctx.show(id) catch |e| return errorPage(r, statusOf(e), "Can't show that report", reports.describe(e, &r.client.?));
    const rep = d.report;
    const forge = forgeBase(r);
    var note: []const u8 = "";
    var lines: []const CodeLine = &.{};
    var commit: []const u8 = "";
    if (d.excerpt) |ex| {
        lines = try highlightLines(a, rep.file, ex.lines, ex.first, ex.line);
        commit = ex.commit[0..@min(ex.commit.len, 10)];
        note = if (ex.at_filed_commit)
            try std.fmt.allocPrint(a, "At {s}, the commit it was filed against.", .{commit})
        else if (ex.changed)
            "The line no longer reads as it did when this was filed; showing HEAD around its old line number."
        else if (ex.line != ex.filed_line)
            try std.fmt.allocPrint(a, "The line has moved: it was line {d} when filed and is line {d} at HEAD.", .{ ex.filed_line, ex.line })
        else
            "At HEAD.";
    } else note = "The file isn't in the repo's HEAD, so only the filed line is shown.";
    const where: []const u8 = if (rep.changed)
        "The filed text is no longer in the work tree's file."
    else if (rep.moved)
        try std.fmt.allocPrint(a, "In the work tree it is line {d} now.", .{rep.current_line.?})
    else
        "";
    const crumbs = [_]theme.Link{
        .{ .label = "Radar", .href = "/" },
        .{ .label = rep.repo, .href = try std.fmt.allocPrint(a, "/?status=all&repo={s}", .{try urlEncode(a, rep.repo)}), .avatar = try theme.avatar(a, rep.repo, "cpull-identicon-sm") },
        .{ .label = rep.short() },
    };
    var tasks: std.ArrayList(theme.Link) = .empty;
    try tasks.append(a, .{ .label = "Back to reports", .href = "/", .icon = "arrow-up-circle" });
    if (forge.len > 0 and rep.url.len > 0) try tasks.append(a, .{ .label = "Open in Forge", .href = try std.fmt.allocPrint(a, "{s}{s}", .{ forge, rep.url }), .icon = "box-arrow-up-right" });
    try tasks.append(a, .{ .label = "Report another line", .href = try std.fmt.allocPrint(a, "/new?repo={s}&file={s}&line={d}", .{ try urlEncode(a, rep.repo), try urlEncode(a, rep.file), rep.current_line orelse rep.line }), .icon = "plus-circle" });
    return page(r, .ok, "radar/report.html", .{
        .layout = try layout(r, .reports, try std.fmt.allocPrint(a, "{s} · Radar", .{rep.title}), &crumbs, tasks.items, &.{}, &.{}),
        .page = .{
            .row = try rowOf(r, rep),
            .note = rep.note orelse "",
            .quote = rep.quote orelse "",
            .author = rep.author orelse "",
            .commit = rep.commit orelse "",
            .forge_href = if (forge.len > 0 and rep.url.len > 0) try std.fmt.allocPrint(a, "{s}{s}", .{ forge, rep.url }) else "",
            .lines = lines,
            .excerpt_note = note,
            .excerpt_commit = commit,
            .where = where,
            .action = try std.fmt.allocPrint(a, "/reports/{s}/{s}", .{ rep.id, if (rep.closed()) "reopen" else "close" }),
        },
    });
}

const Form = struct {
    repo: []const u8 = "",
    file: []const u8 = "",
    line: []const u8 = "",
    quote: []const u8 = "",
    note: []const u8 = "",
    title: []const u8 = "",
    labels: []const u8 = "",
    ref: []const u8 = "",
};

fn newPage(r: *Req, problem: ?[]const u8, form_in: Form) !void {
    const a = r.a;
    var form = form_in;
    if (problem == null) inline for (@typeInfo(Form).@"struct".field_names) |name| {
        if (r.param(name)) |v| @field(form, name) = v;
    };
    var flashes: std.ArrayList(theme.Flash) = .empty;
    if (problem) |p| try flashes.append(a, .{ .text = p, .kind = "danger" });
    var repo_names: std.ArrayList([]const u8) = .empty;
    if (r.ctx()) |c| {
        var ctx = c;
        if (ctx.repos()) |list| {
            for (list) |repo| if (repo.cloned) try repo_names.append(a, if (repo.name.len == 0) "." else repo.name);
        } else |e| try flashes.append(a, .{ .text = reports.describe(e, &r.client.?), .kind = "danger" });
    } else try flashes.append(a, .{ .text = r.why, .kind = "warning" });
    const crumbs = [_]theme.Link{ .{ .label = "Radar", .href = "/" }, .{ .label = "File a report" } };
    const tasks = [_]theme.Link{.{ .label = "Back to reports", .href = "/", .icon = "arrow-up-circle" }};
    return page(r, if (problem != null) .bad_request else .ok, "radar/new.html", .{
        .layout = try layout(r, .new, "File a report · Radar", &crumbs, &tasks, &.{}, flashes.items),
        .page = .{ .form = form, .repos = repo_names.items },
    });
}

fn formFile(r: *Req) !void {
    const body = try r.body();
    var form: Form = .{};
    inline for (@typeInfo(Form).@"struct".field_names) |name| {
        if (formValue(r.a, body, name)) |v| @field(form, name) = std.mem.trim(u8, v, " \t\r\n");
    }
    const line = std.fmt.parseInt(u64, form.line, 10) catch return newPage(r, "The line is a number, from 1.", form);
    var ctx = r.ctx() orelse return newPage(r, r.why, form);
    const filed = ctx.file(.{
        .repo = form.repo,
        .file = form.file,
        .line = line,
        .quote = form.quote,
        .note = form.note,
        .title = if (form.title.len > 0) form.title else null,
        .labels = form.labels,
        .source = "radar",
        .ref = if (form.ref.len > 0) form.ref else null,
    }) catch |e| return newPage(r, reports.describe(e, &r.client.?), form);
    return r.redirect(try std.fmt.allocPrint(r.a, "/reports/{s}", .{filed.id}));
}

fn formStatus(r: *Req, id: []const u8, closed: bool) !void {
    _ = r.body() catch {};
    var ctx = r.ctx() orelse return errorPage(r, .service_unavailable, "cpull isn't running", r.why);
    const done = ctx.setStatus(id, closed) catch |e| return errorPage(r, statusOf(e), "Can't change that report", reports.describe(e, &r.client.?));
    return r.redirect(try std.fmt.allocPrint(r.a, "/reports/{s}", .{done.id}));
}

fn errorPage(r: *Req, status: std.http.Status, title: []const u8, text: []const u8) !void {
    const crumbs = [_]theme.Link{ .{ .label = "Radar", .href = "/" }, .{ .label = title } };
    const tasks = [_]theme.Link{.{ .label = "Back to reports", .href = "/", .icon = "arrow-up-circle" }};
    const flashes = [_]theme.Flash{.{ .text = text, .kind = "danger" }};
    return page(r, status, "radar/index.html", .{
        .layout = try layout(r, .none, title, &crumbs, &tasks, &.{}, &flashes),
        .page = .{ .heading = title, .tabs = &[_]theme.Link{}, .rows = &[_]Row{}, .status = "", .empty = "", .connected = false, .new_href = "/new" },
    });
}

test "templates parse" {
    try theme.parseAll(&templates, std.testing.allocator);
}

test idRoute {
    try std.testing.expectEqualStrings("ab12", idRoute("/api/reports/ab12/close", "/api/reports/", "/close").?);
    try std.testing.expect(idRoute("/api/reports//close", "/api/reports/", "/close") == null);
    try std.testing.expect(idRoute("/api/reports/a/b/close", "/api/reports/", "/close") == null);
}

test formValue {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a b/c", formValue(arena.allocator(), "x=1&file=a+b%2Fc", "file").?);
    try std.testing.expect(formValue(arena.allocator(), "x=1", "file") == null);
}
