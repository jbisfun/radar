//! radar: line-anchored reports for a pull workspace, stored as cpull issues
//! (theme docs/workspace-tools.md §7). See cli.zig for the commands.
const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    var iter = try init.minimal.args.iterateAllocator(a);
    _ = iter.next();
    var args: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |arg| try args.append(a, arg);

    var out_buf: [16 * 1024]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    var err = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
    const env = init.environ_map;
    return cli.run(init.io, init.gpa, a, args.items, .{
        .pull_root = env.get("PULL_ROOT"),
        .cpull_addr = env.get("CPULL_ADDR"),
    }, &out.interface, &err.interface);
}

test {
    _ = @import("anchor.zig");
    _ = @import("cli.zig");
    _ = @import("cpull.zig");
    _ = @import("git.zig");
    _ = @import("mcp.zig");
    _ = @import("reports.zig");
    _ = @import("server.zig");
    _ = @import("workspace.zig");
    _ = @import("test.zig");
}
