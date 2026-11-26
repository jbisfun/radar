//! `radar mcp`: an MCP server (stdio, parley) with the report tools pull's
//! `cpull_report*` tools had, renamed `radar_*`. Each call connects to cpull's
//! API, like the CLI; answers are the CLI's text.
const std = @import("std");
const parley = @import("parley");
const cpull = @import("cpull.zig");
const reports = @import("reports.zig");
const cli = @import("cli.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    root: []const u8,
    cpull_addr: ?[]const u8 = null,
};

const Ctx = struct { io: Io, opts: Options };

const report_schema =
    \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"id":{"description":"Report id (a unique prefix will do).","type":"string"}},"required":["id"],"type":"object"}
;

const Def = struct {
    name: []const u8,
    description: []const u8,
    schema: []const u8,
    run: *const fn (ctx: *reports.Ctx, a: Allocator, args: Args) anyerror![]const u8,
};

pub const defs = [_]Def{
    .{
        .name = "radar_report",
        .description = "radar: file a report, a cpull issue anchored to a line of code, in the repo it points at (`radar add`). The line's text is read from the file and the note becomes the issue description. Returns the report id (a cpull issue id) and its location.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"file":{"description":"Path relative to the repo.","type":"string"},"line":{"description":"1-based line number.","minimum":1,"type":"integer"},"note":{"description":"What's wrong here, why, and the fix (markdown).","type":["string","null"]},"quote":{"description":"The selected text, if narrower than the line.","type":["string","null"]},"repo":{"description":"Repo name from the pullfile, or . for the workspace's events repo.","type":"string"},"source":{"description":"Where the report came from (default \"mcp\").","type":["string","null"]},"title":{"description":"Default: the note's first line.","type":["string","null"]}},"required":["repo","file","line"],"type":"object"}
        ,
        .run = report,
    },
    .{
        .name = "radar_report_close",
        .description = "radar: close a report (its cpull issue).",
        .schema = report_schema,
        .run = close,
    },
    .{
        .name = "radar_report_reopen",
        .description = "radar: reopen a closed report.",
        .schema = report_schema,
        .run = reopen,
    },
    .{
        .name = "radar_report_show",
        .description = "radar: one report: where it points (and where that line is now), its note, its cpull web UI path and the code around it.",
        .schema = report_schema,
        .run = show,
    },
    .{
        .name = "radar_reports",
        .description = "radar: reports (line-anchored cpull issues) across every repo, oldest first: id, repo/file:line (and the line now, if it moved), filing time, the line's text and the note. Open ones unless `all`.",
        .schema =
        \\{"$schema":"https://json-schema.org/draft/2020-12/schema","properties":{"all":{"default":false,"description":"Closed reports too.","type":"boolean"}},"type":"object"}
        ,
        .run = list,
    },
};

const Args = struct {
    obj: ?std.json.ObjectMap,

    fn get(args: Args, key: []const u8) ?std.json.Value {
        const o = args.obj orelse return null;
        const v = o.get(key) orelse return null;
        return if (v == .null) null else v;
    }
    fn str(args: Args, key: []const u8) ?[]const u8 {
        const v = args.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }
    fn need(args: Args, key: []const u8) ![]const u8 {
        return args.str(key) orelse error.MissingArgument;
    }
    fn int(args: Args, key: []const u8) ?i64 {
        const v = args.get(key) orelse return null;
        return switch (v) {
            .integer => |i| i,
            .float => |f| if (f == @trunc(f)) @intFromFloat(f) else null,
            else => null,
        };
    }
    fn flag(args: Args, key: []const u8) bool {
        const v = args.get(key) orelse return false;
        return v == .bool and v.bool;
    }
};

fn text(a: Allocator, comptime f: anytype, args: anytype) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try @call(.auto, f, .{&w.writer} ++ args);
    return w.written();
}

fn report(ctx: *reports.Ctx, a: Allocator, args: Args) ![]const u8 {
    const line = args.int("line") orelse return error.MissingLine;
    if (line < 1) return error.InvalidLineNumber;
    const r = try ctx.file(.{
        .repo = try args.need("repo"),
        .file = try args.need("file"),
        .line = @intCast(line),
        .note = args.str("note"),
        .quote = args.str("quote"),
        .title = args.str("title"),
        .source = args.str("source") orelse "mcp",
    });
    return text(a, cli.writeFiled, .{r});
}

fn list(ctx: *reports.Ctx, a: Allocator, args: Args) ![]const u8 {
    const all = args.flag("all");
    return text(a, cli.writeList, .{ try ctx.list(.{ .status = if (all) "all" else "open" }), all });
}

fn show(ctx: *reports.Ctx, a: Allocator, args: Args) ![]const u8 {
    return text(a, cli.writeShow, .{try ctx.show(try args.need("id"))});
}

fn close(ctx: *reports.Ctx, a: Allocator, args: Args) ![]const u8 {
    const r = try ctx.setStatus(try args.need("id"), true);
    return std.fmt.allocPrint(a, "{s} closed", .{r.short()});
}

fn reopen(ctx: *reports.Ctx, a: Allocator, args: Args) ![]const u8 {
    const r = try ctx.setStatus(try args.need("id"), false);
    return std.fmt.allocPrint(a, "{s} reopened", .{r.short()});
}

const Tool = struct {
    h: parley.ToolHandler = .{ .callFn = call },
    ctx: *const Ctx,
    def: Def,

    fn call(h: *parley.ToolHandler, c: *parley.Call, raw: ?[]const u8) parley.Call.Error!parley.ToolResult {
        const t: *Tool = @fieldParentPtr("h", h);
        const a = c.arena;
        const value: ?std.json.Value = if (raw) |r| std.json.parseFromSliceLeaky(std.json.Value, a, r, .{}) catch return .failure("arguments aren't json") else null;
        const args: Args = .{ .obj = if (value) |v| (if (v == .object) v.object else null) else null };
        var why: []const u8 = "";
        var client = cpull.Client.connect(t.ctx.io, a, t.ctx.opts.root, t.ctx.opts.cpull_addr, &why) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .failure(why),
        };
        defer client.deinit();
        var ctx: reports.Ctx = .{ .io = t.ctx.io, .a = a, .root = t.ctx.opts.root, .client = &client };
        const out = t.def.run(&ctx, a, args) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingArgument => return .failure("missing a required argument"),
            error.MissingLine => return .failure("line is required"),
            else => return .failure(reports.describe(e, &client)),
        };
        return .ofText(out);
    }
};

pub const instructions = "radar: line-anchored reports for the pull workspace. A report is a cpull issue in the repo it points at, " ++
    "anchored to a file and line (radar reads the line's text from the work tree and finds it again when the code moves). " ++
    "File one per distinct problem with radar_report; list with radar_reports.";

/// Serves MCP on stdin/stdout until the client closes stdin.
pub fn serve(io: Io, gpa: Allocator, opts: Options) !void {
    const ctx: Ctx = .{ .io = io, .opts = opts };
    var server = try parley.Server.init(gpa, io, .{
        .info = .{ .name = "radar", .version = cli.version },
        .instructions = instructions,
        .logging = false,
        .validator = null,
    });
    defer server.deinit(io);
    var handlers: [defs.len]Tool = undefined;
    for (&handlers, defs) |*t, d| {
        t.* = .{ .ctx = &ctx, .def = d };
        try server.addDynamicTool(io, .{ .name = d.name, .description = d.description, .input_schema = d.schema }, &t.h);
    }
    var in_buffer: [64 * 1024]u8 = undefined;
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, &in_buffer);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);
    try parley.stdio.serve(io, gpa, &server, .fromFile(&stdin), .fromFile(&stdout), .{});
}

test "tool schemas are json, sorted by name" {
    for (defs, 0..) |d, i| {
        const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, d.schema, .{});
        v.deinit();
        if (i > 0) try std.testing.expect(std.mem.lessThan(u8, defs[i - 1].name, d.name));
    }
}
