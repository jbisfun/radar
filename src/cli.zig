//! radar's command line, compatible with the old Rust radar and `cpull report`:
//!
//!   radar [add] REPO FILE LINE [-q QUOTE] [-n NOTE] [--title T] [--labels L] [--source S] [--json]
//!   radar list [--all] [--json]
//!   radar show ID [--json] / radar close ID / radar reopen ID
//!   radar migrate FILE        (the old radar's `radar list --all --json`; - = stdin)
//!   radar serve [--listen ADDR]
//!   radar mcp
//!
//! Every command but serve/mcp talks to cpull's API directly.
const std = @import("std");
const clap = @import("clap");
const discovery = @import("discovery");
const cpull = @import("cpull.zig");
const reports = @import("reports.zig");
const workspace = @import("workspace.zig");
const server = @import("server.zig");
const mcp = @import("mcp.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const version = "0.2.0";

pub const usage =
    \\usage: radar [add] REPO FILE LINE [-q QUOTE] [-n NOTE] [--title T] [--labels L] [--source S] [--json]
    \\       radar list [--all] [--json]
    \\       radar show ID [--json]
    \\       radar close ID | radar reopen ID
    \\       radar migrate FILE
    \\       radar serve [--listen ADDR]
    \\       radar mcp
    \\
    \\Line-anchored reports for a pull workspace, stored as cpull issues (filed
    \\in the repo they point at, labelled `report`). REPO is a pullfile repo, or
    \\"." for the workspace's events repo; FILE is relative to it and the line's
    \\text is read from the work tree. ID is a report (issue) id; a unique prefix
    \\will do.
    \\
    \\  add       file a report (-n note: the issue description, its first line
    \\            the title unless --title; -q the selected text, if narrower
    \\            than the line; --source cli|ycode|wiki|mcp, default cli)
    \\  list      open reports across every repo (--all: closed too), with where
    \\            each line is now
    \\  show      one report and the code around it
    \\  migrate   file the reports of the old radar.db (`radar list --all --json`
    \\            of the Rust radar; - reads stdin)
    \\  serve     the web UI and JSON API (default 127.0.0.1:8746)
    \\  mcp       an MCP server on stdio (radar_report, radar_reports, ...)
    \\
    \\  --root DIR        the workspace (default $PULL_ROOT, else the nearest
    \\                    parent holding pullfile.plist)
    \\  --addr HOST:PORT  cpull's address (default $CPULL_ADDR, else
    \\                    .pull/cpull/serve.addr, else 127.0.0.1:8080)
    \\
;

const params = clap.parseParamsComptime(
    \\-h, --help
    \\-V, --version
    \\-q, --quote <str>
    \\-n, --note <str>
    \\--title <str>
    \\--labels <str>
    \\--source <str>
    \\--ref <str>
    \\--all
    \\--json
    \\--root <str>
    \\--addr <str>
    \\--listen <str>
    \\<str>...
    \\
);

pub const Action = enum { add, list, show, close, reopen, migrate, serve, mcp };

/// The action `radar ARGS...` names: a leading command with its arity, else an
/// add with REPO FILE LINE (so a repo named "list" still works).
pub fn parseAction(positional: []const []const u8) ?struct { Action, []const []const u8 } {
    if (positional.len == 3) return .{ .add, positional };
    if (positional.len == 0) return null;
    const action = std.meta.stringToEnum(Action, positional[0]) orelse return null;
    const rest = positional[1..];
    const ok = switch (action) {
        .add => rest.len == 3,
        .list, .serve, .mcp => rest.len == 0,
        .show, .close, .reopen, .migrate => rest.len == 1,
    };
    return if (ok) .{ action, rest } else null;
}

pub const Env = struct {
    pull_root: ?[]const u8 = null,
    cpull_addr: ?[]const u8 = null,
};

/// Runs radar with `args` (without argv[0]); the process exit code.
pub fn run(io: Io, gpa: Allocator, a: Allocator, args: []const []const u8, env: Env, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var diag: clap.Diagnostic = .{};
    var iter = clap.args.SliceIterator{ .args = args };
    const res = clap.parseEx(clap.Help, &params, .{ .str = clap.parsers.string }, &iter, .{ .diagnostic = &diag, .allocator = a }) catch |e| {
        try err.writeAll("radar: ");
        diag.report(err, e) catch {};
        try err.writeAll(usage);
        try err.flush();
        return 2;
    };
    const o = res.args;
    if (o.help != 0) {
        try out.writeAll(usage);
        try out.flush();
        return 0;
    }
    if (o.version != 0) {
        try out.print("radar {s}\n", .{version});
        try out.flush();
        return 0;
    }
    const action, const pos = parseAction(res.positionals[0]) orelse {
        if (res.positionals[0].len > 0) try err.print("radar: can't read `{s}`\n", .{res.positionals[0][0]});
        try err.writeAll(usage);
        try err.flush();
        return 2;
    };

    const root = (workspace.findRoot(io, a, o.root, env.pull_root) catch |e| {
        try err.print("radar: the workspace root: {s}\n", .{@errorName(e)});
        try err.flush();
        return 1;
    }) orelse {
        try err.writeAll("radar: no pullfile.plist here or in any parent (pass --root or set PULL_ROOT)\n");
        try err.flush();
        return 1;
    };
    const cpull_addr = o.addr orelse env.cpull_addr;

    switch (action) {
        .serve => {
            const listen = o.listen orelse discovery.Tool.radar.defaultAddr();
            server.serve(io, gpa, .{ .root = root, .listen = listen, .cpull_addr = cpull_addr, .log = err }) catch |e| {
                try err.print("radar serve: {s}\n", .{switch (e) {
                    error.AlreadyServing => "another radar server already serves this workspace",
                    error.AddressInUse => "the address is in use",
                    error.InvalidAddress => "--listen wants HOST:PORT",
                    else => @errorName(e),
                }});
                try err.flush();
                return 1;
            };
            return 0;
        },
        .mcp => {
            try mcp.serve(io, gpa, .{ .root = root, .cpull_addr = cpull_addr });
            return 0;
        },
        else => {},
    }

    var why: []const u8 = "";
    var client = cpull.Client.connect(io, a, root, cpull_addr, &why) catch {
        try err.print("radar {s}: {s}\n", .{ @tagName(action), why });
        try err.flush();
        return 1;
    };
    defer client.deinit();
    var ctx: reports.Ctx = .{ .io = io, .a = a, .root = root, .client = &client };
    dispatch(&ctx, action, pos, o, out, err) catch |e| {
        try err.print("radar {s}: {s}\n", .{ @tagName(action), reports.describe(e, &client) });
        try err.flush();
        return 1;
    };
    try out.flush();
    try err.flush();
    return 0;
}

fn dispatch(ctx: *reports.Ctx, action: Action, pos: []const []const u8, o: anytype, out: *std.Io.Writer, err: *std.Io.Writer) !void {
    switch (action) {
        .add => {
            const line = std.fmt.parseInt(u64, pos[2], 10) catch return error.InvalidLineNumber;
            const r = try ctx.file(.{
                .repo = pos[0],
                .file = pos[1],
                .line = line,
                .quote = o.quote,
                .note = o.note,
                .title = o.title,
                .labels = o.labels,
                .source = o.source,
                .ref = o.ref,
            });
            if (o.json != 0) try writeJson(out, r) else try writeFiled(out, r);
        },
        .list => {
            const list = try ctx.list(.{ .status = if (o.all != 0) "all" else "open" });
            if (o.json != 0) return writeJson(out, list);
            try writeList(out, list, o.all != 0);
        },
        .show => {
            const d = try ctx.show(pos[0]);
            if (o.json != 0) return writeJson(out, d);
            try writeShow(out, d);
        },
        .close, .reopen => {
            const r = try ctx.setStatus(pos[0], action == .close);
            try out.print("{s} {s}\n", .{ r.short(), if (action == .close) "closed" else "reopened" });
        },
        .migrate => try ctx.migrate(pos[0], out, err),
        .serve, .mcp => unreachable,
    }
}

// ---------------------------------------------------------------- text output

pub fn writeJson(out: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
}

pub fn writeFiled(out: *std.Io.Writer, r: reports.RadarReport) !void {
    try out.print("{s} {s}/{s}:{d}\n", .{ r.short(), r.repo, r.file, r.line });
}

/// One report as `radar list` prints it (cpull report's layout, plus where
/// its line is now when that differs).
pub fn writeText(out: *std.Io.Writer, r: reports.RadarReport) !void {
    try out.print("{s} {s}/{s}:{d}{s}", .{ r.short(), r.repo, r.file, r.line, if (r.closed()) " (closed)" else "" });
    if (r.changed) {
        try out.writeAll(" (changed)");
    } else if (r.moved) if (r.current_line) |l| try out.print(" (now line {d})", .{l});
    try out.print("  {s}\n    {s}\n", .{ r.created, std.mem.trim(u8, r.line_text, " \t\r") });
    if (r.note) |note| if (note.len > 0) try out.print("    {s}\n", .{note});
}

pub fn writeList(out: *std.Io.Writer, list: []const reports.RadarReport, all: bool) !void {
    for (list) |r| try writeText(out, r);
    if (list.len == 0) try out.print("no {s}reports\n", .{if (all) "" else "open "});
}

pub fn writeShow(out: *std.Io.Writer, d: reports.Detail) !void {
    try writeText(out, d.report);
    try out.print("    {s}\n", .{d.report.url});
    const ex = d.excerpt orelse return;
    try out.print("\n  at {s}{s}\n", .{ ex.commit[0..@min(ex.commit.len, 10)], if (ex.at_filed_commit) " (filed against)" else " (HEAD)" });
    for (ex.lines, 0..) |text, i| {
        const n = ex.first + i;
        try out.print("  {s} {d: >5} | {s}\n", .{ if (n == ex.line) ">" else " ", n, text });
    }
}

test parseAction {
    try std.testing.expectEqual(Action.add, parseAction(&.{ "list", "a.zig", "3" }).?[0]);
    try std.testing.expectEqual(Action.list, parseAction(&.{"list"}).?[0]);
    try std.testing.expectEqual(Action.close, parseAction(&.{ "close", "ab12" }).?[0]);
    try std.testing.expect(parseAction(&.{ "close", "a", "b", "c" }) == null);
    try std.testing.expect(parseAction(&.{"pull"}) == null);
    try std.testing.expectEqual(Action.add, parseAction(&.{ "add", "pull", "a.zig", "3" }).?[0]);
    try std.testing.expectEqualStrings("pull", parseAction(&.{ "add", "pull", "a.zig", "3" }).?[1][0]);
    try std.testing.expectEqual(Action.serve, parseAction(&.{"serve"}).?[0]);
}
