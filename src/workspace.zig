//! The pull workspace radar works in: its root (`--root`, else $PULL_ROOT,
//! else the nearest ancestor of the cwd holding pullfile.plist) and the
//! pullfile's events repo (`cpull.events`), the repo "." names.
const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The workspace root as an absolute path, or null when there is none.
pub fn findRoot(io: Io, a: Allocator, explicit: ?[]const u8, env_root: ?[]const u8) !?[]const u8 {
    const cwd = Io.Dir.cwd();
    if (explicit orelse (if (env_root) |e| (if (e.len > 0) e else null) else null)) |dir| {
        return cwd.realPathFileAlloc(io, dir, a) catch |e| switch (e) {
            error.FileNotFound => return error.RootNotFound,
            else => |x| return x,
        };
    }
    var dir: []const u8 = try cwd.realPathFileAlloc(io, ".", a);
    while (true) {
        const candidate = try std.fs.path.join(a, &.{ dir, "pullfile.plist" });
        if (cwd.access(io, candidate, .{})) |_| return dir else |_| {}
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// The pullfile's `cpull` section `events` repo name, or null. A plain scan
/// of the plist (pull writes it in one fixed layout), so radar needs no plist
/// parser for one string.
pub fn eventsRepo(io: Io, a: Allocator, root: []const u8) ?[]const u8 {
    const path = std.fs.path.join(a, &.{ root, "pullfile.plist" }) catch return null;
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch return null;
    return eventsIn(text);
}

fn eventsIn(text: []const u8) ?[]const u8 {
    // the top-level `cpull` key is one tab deep
    const key = "\n\t<key>cpull</key>";
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    const end = std.mem.indexOf(u8, rest, "\n\t</dict>") orelse return null;
    const section = rest[0..end];
    const ev = std.mem.indexOf(u8, section, "<key>events</key>") orelse return null;
    const after = section[ev..];
    const open = std.mem.indexOf(u8, after, "<string>") orelse return null;
    const close = std.mem.indexOf(u8, after, "</string>") orelse return null;
    if (close < open) return null;
    return after[open + "<string>".len .. close];
}

test eventsIn {
    const plist =
        "<plist version=\"1.0\">\n<dict>\n\t<key>jobs</key>\n\t<array/>\n\t<key>cpull</key>\n\t<dict>\n\t\t<key>events</key>\n\t\t<string>dotenv</string>\n\t</dict>\n\t<key>repos</key>\n</dict>\n</plist>";
    try std.testing.expectEqualStrings("dotenv", eventsIn(plist).?);
    try std.testing.expectEqual(@as(?[]const u8, null), eventsIn("<dict>\n\t<key>repos</key>\n</dict>"));
}
