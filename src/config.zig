const std = @import("std");
const protocol = @import("protocol.zig");

pub var launch: ?Launch = null;

pub const Launch = struct {
    configurations: []std.json.ArrayHashMap(std.json.Value),
};

pub const Path = std.BoundedArray(u8, std.fs.max_path_bytes);
pub fn find_launch_json() !?Path {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&buf);

    var opened = try std.fs.openDirAbsolute(cwd, .{ .iterate = true });
    var iter = opened.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        if (std.mem.eql(u8, entry.name, "launch.json")) {
            var fixed_buf: [std.fs.max_path_bytes]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&fixed_buf);

            const dir = try std.process.getCwd(&buf);
            const path = try std.fs.path.join(fixed.allocator(), &.{ dir, "launch.json" });
            return try Path.fromSlice(path);
        }
    }

    return null;
}

pub fn open_and_parse_launch_json(allocator: std.mem.Allocator, path: Path) !std.json.Parsed(Launch) {
    const file = try std.fs.openFileAbsolute(path.slice(), .{ .mode = .read_only });
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(content);
    return std.json.parseFromSlice(Launch, allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
