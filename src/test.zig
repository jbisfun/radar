//! radar end to end over HTTP against a fake cpull (the contract's /api
//! routes radar calls, in memory): filing builds the anchor, listing relocates
//! it, show reads the excerpt at the filed commit, close/reopen go through
//! cpull, cross-origin writes are refused and every page renders.
const std = @import("std");
const cpull = @import("cpull.zig");
const server = @import("server.zig");
const reports = @import("reports.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Fake = struct {
    root: []const u8,
    mutex: std.Io.Mutex = .init,
    issues: std.ArrayList(cpull.Issue) = .empty,
    a: Allocator,
    posts: usize = 0,
    origin_seen: bool = false,
};

fn fakeServe(io: Io, srv: *Io.net.Server, fake: *Fake) void {
    while (true) {
        const stream = srv.accept(io) catch return;
        defer stream.close(io);
        var recv: [8192]u8 = undefined;
        var send: [8192]u8 = undefined;
        var br = stream.reader(io, &recv);
        var bw = stream.writer(io, &send);
        var http = std.http.Server.init(&br.interface, &bw.interface);
        while (http.reader.state == .ready) {
            var request = http.receiveHead() catch break;
            fakeHandle(io, fake, &request) catch break;
        }
    }
}

fn json(request: *std.http.Server.Request, a: Allocator, status: std.http.Status, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(a, value, .{});
    try request.respond(body, .{ .status = status, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn fakeHandle(io: Io, fake: *Fake, request: *std.http.Server.Request) !void {
    fake.mutex.lockUncancelable(io);
    defer fake.mutex.unlock(io);
    const a = fake.a;
    const target = try a.dupe(u8, request.head.target);
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    var it = request.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "origin")) {
        fake.origin_seen = true;
    };
    if (std.mem.eql(u8, path, "/api/health")) return json(request, a, .ok, .{ .ok = true, .tool = "cpull", .root = fake.root });
    if (std.mem.eql(u8, path, "/api/repos")) return json(request, a, .ok, &[_]cpull.Repo{.{ .name = "alpha", .path = "alpha" }});
    if (std.mem.eql(u8, path, "/api/reports")) {
        const all = std.mem.indexOf(u8, target, "status=all") != null;
        var out: std.ArrayList(cpull.Report) = .empty;
        for (fake.issues.items) |i| if (all or std.mem.eql(u8, i.status, "open")) try out.append(a, try cpull.Report.fromIssue(i));
        return json(request, a, .ok, out.items);
    }
    if (request.head.method == .POST and std.mem.eql(u8, path, "/api/issues")) {
        var buf: [4096]u8 = undefined;
        const body = try (try request.readerExpectContinue(&buf)).allocRemaining(a, .limited(1 << 20));
        const new = try std.json.parseFromSliceLeaky(cpull.NewIssue, a, body, .{ .allocate = .alloc_always });
        fake.posts += 1;
        const id = try std.fmt.allocPrint(a, "{d:0>2}c0ffee{d:0>24}", .{ fake.posts, fake.posts });
        const issue: cpull.Issue = .{ .id = id, .repo = new.repo, .title = new.title, .description = new.description, .labels = new.labels, .status = "open", .author = "pull", .created = "2026-11-26T12:00:00Z", .url = try std.fmt.allocPrint(a, "/o:{s}/issues/{s}", .{ new.repo, id }), .anchor = new.anchor };
        try fake.issues.append(a, issue);
        return json(request, a, .created, issue);
    }
    if (request.head.method == .POST and std.mem.startsWith(u8, path, "/api/issues/alpha/")) {
        _ = try (try request.readerExpectContinue(&[_]u8{})).discardRemaining();
        const rest = path["/api/issues/alpha/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return json(request, a, .not_found, .{ .@"error" = "no" });
        for (fake.issues.items) |*i| if (std.mem.eql(u8, i.id, rest[0..slash])) {
            i.status = if (std.mem.eql(u8, rest[slash + 1 ..], "close")) "closed" else "open";
            return json(request, a, .ok, i.*);
        };
        return json(request, a, .not_found, .{ .@"error" = "no such issue" });
    }
    return json(request, a, .not_found, .{ .@"error" = "not found" });
}

const Got = struct { status: std.http.Status, body: []const u8 };

fn fetch(a: Allocator, client: *std.http.Client, port: u16, method: std.http.Method, path: []const u8, payload: ?[]const u8, origin: ?[]const u8) !Got {
    var out: std.Io.Writer.Allocating = .init(a);
    const res = try client.fetch(.{
        .location = .{ .url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}{s}", .{ port, path }) },
        .method = method,
        .payload = payload,
        .response_writer = &out.writer,
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .extra_headers = if (origin) |o| &.{.{ .name = "origin", .value = o }} else &.{},
    });
    return .{ .status = res.status, .body = out.written() };
}

fn has(haystack: []const u8, needle: []const u8) bool {
    if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    std.debug.print("missing {s} in:\n{s}\n", .{ needle, haystack[0..@min(haystack.len, 3000)] });
    return false;
}

fn git(io: Io, a: Allocator, dir: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(a, &.{ "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid" });
    try argv.appendSlice(a, args);
    const r = try std.process.run(a, io, .{ .argv = argv.items });
    try std.testing.expect(r.term.success());
}

test "radar over HTTP against a fake cpull" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "alpha");
    try tmp.dir.writeFile(io, .{ .sub_path = "pullfile.plist", .data = "<plist/>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha/a.zig", .data = "const a = 1;\nconst b = 2;\nconst c = 3;\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const alpha = try std.fs.path.join(a, &.{ root, "alpha" });
    try git(io, a, alpha, &.{ "init", "-q", "-b", "main" });
    try git(io, a, alpha, &.{ "add", "-A" });
    try git(io, a, alpha, &.{ "commit", "-qm", "init" });

    var fake: Fake = .{ .root = root, .a = a };
    const any = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var fake_srv = try any.listen(io, .{});
    (try std.Thread.spawn(.{}, fakeServe, .{ io, &fake_srv, &fake })).detach();
    const cpull_addr = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{fake_srv.socket.address.getPort()});

    var app: server.App = .{ .io = io, .gpa = std.heap.smp_allocator, .root = root, .cpull_addr = cpull_addr };
    var srv = try any.listen(io, .{});
    const port = srv.socket.address.getPort();
    (try std.Thread.spawn(.{}, server.acceptLoop, .{ &app, &srv })).detach();
    var client: std.http.Client = .{ .allocator = a, .io = io };

    const health = try fetch(a, &client, port, .GET, "/api/health", null, null);
    try std.testing.expect(has(health.body, "\"tool\":\"radar\""));

    // file on line 2 (committed, so the commit is recorded), with labels
    const filed = try fetch(a, &client, port, .POST, "/api/reports", "{\"repo\":\"alpha\",\"file\":\"./a.zig\",\"line\":2,\"quote\":\"b\",\"note\":\"why b\",\"labels\":\"ui\",\"source\":\"wiki\"}", null);
    try std.testing.expectEqual(std.http.Status.created, filed.status);
    try std.testing.expect(has(filed.body, "\"line_text\":\"const b = 2;\""));
    try std.testing.expect(has(filed.body, "\"current_line\":2,\"moved\":false,\"changed\":false"));
    try std.testing.expectEqualStrings("ui report", fake.issues.items[0].labels);
    try std.testing.expectEqual(40, fake.issues.items[0].anchor.?.commit.?.len);
    try std.testing.expectEqualStrings("wiki", fake.issues.items[0].anchor.?.source.?);
    const id = fake.issues.items[0].id;

    // the line moves down two in the work tree
    try tmp.dir.writeFile(io, .{ .sub_path = "alpha/a.zig", .data = "// x\n// y\nconst a = 1;\nconst b = 2;\nconst c = 3;\n" });
    const listed = try fetch(a, &client, port, .GET, "/api/reports", null, null);
    try std.testing.expect(has(listed.body, "\"current_line\":4,\"moved\":true,\"changed\":false"));
    const shown = try fetch(a, &client, port, .GET, try std.fmt.allocPrint(a, "/api/reports/{s}", .{id[0..8]}), null, null);
    try std.testing.expect(has(shown.body, "\"excerpt\":{\"file\":\"a.zig\",\"line\":2,\"filed_line\":2,\"first\":1,\"lines\":[\"const a = 1;\",\"const b = 2;\",\"const c = 3;\"]"));
    try std.testing.expect(has(shown.body, "\"at_filed_commit\":true"));
    const reloc = try fetch(a, &client, port, .POST, "/api/relocate", "{\"repo\":\"alpha\",\"file\":\"a.zig\",\"line\":1,\"line_text\":\"const c = 3;\"}", null);
    try std.testing.expectEqualStrings("{\"line\":5,\"changed\":false}", reloc.body);

    // writes from another origin are refused; radar itself sends none to cpull
    const evil = try fetch(a, &client, port, .POST, try std.fmt.allocPrint(a, "/api/reports/{s}/close", .{id}), "{}", "http://evil.example");
    try std.testing.expectEqual(std.http.Status.forbidden, evil.status);
    const closed = try fetch(a, &client, port, .POST, try std.fmt.allocPrint(a, "/api/reports/{s}/close", .{id[0..6]}), "{}", null);
    try std.testing.expect(has(closed.body, "\"status\":\"closed\""));
    try std.testing.expect(!fake.origin_seen);
    const open = try fetch(a, &client, port, .GET, "/api/reports", null, null);
    try std.testing.expectEqualStrings("[]", open.body);

    const bad = try fetch(a, &client, port, .POST, "/api/reports", "{\"repo\":\"alpha\",\"file\":\"a.zig\",\"line\":99}", null);
    try std.testing.expectEqual(std.http.Status.bad_request, bad.status);
    try std.testing.expect(has(bad.body, "no such line"));
    const unknown = try fetch(a, &client, port, .POST, "/api/reports", "{\"repo\":\"nope\",\"file\":\"a.zig\",\"line\":1}", null);
    try std.testing.expect(has(unknown.body, "no such repo"));
    const missing = try fetch(a, &client, port, .GET, "/api/reports/ffff", null, null);
    try std.testing.expectEqual(std.http.Status.not_found, missing.status);

    // pages
    const index = try fetch(a, &client, port, .GET, "/?status=all", null, null);
    try std.testing.expectEqual(std.http.Status.ok, index.status);
    try std.testing.expect(has(index.body, "why b"));
    try std.testing.expect(has(index.body, "now line 4"));
    try std.testing.expect(has(index.body, "data-tool=\"radar\""));
    const page = try fetch(a, &client, port, .GET, try std.fmt.allocPrint(a, "/reports/{s}", .{id}), null, null);
    try std.testing.expect(has(page.body, "radar-hit"));
    try std.testing.expect(has(page.body, "hl-zig"));
    try std.testing.expect(has(page.body, "Reopen"));
    const new = try fetch(a, &client, port, .GET, "/new?repo=alpha&file=a.zig&line=3", null, null);
    try std.testing.expect(has(new.body, "<option selected>alpha</option>"));
    const form = try fetch(a, &client, port, .POST, "/reports", "repo=alpha&file=a.zig&line=3&note=from+the+form", null);
    try std.testing.expectEqual(std.http.Status.see_other, form.status);
    try std.testing.expectEqualStrings("radar", fake.issues.items[1].anchor.?.source.?);
    try std.testing.expectEqual(@as(?[]const u8, null), fake.issues.items[1].anchor.?.commit);
    const css = try fetch(a, &client, port, .GET, "/assets/radar.css", null, null);
    try std.testing.expect(has(css.body, ".radar-code"));

    // the CLI's list against the same fake
    var why: []const u8 = "";
    var c = try cpull.Client.connect(io, a, root, cpull_addr, &why);
    defer c.deinit();
    var ctx: reports.Ctx = .{ .io = io, .a = a, .root = root, .client = &c };
    const all = try ctx.list(.{ .status = "all" });
    try std.testing.expectEqual(2, all.len);
    try std.testing.expectError(error.AmbiguousId, ctx.find("0"));
}
