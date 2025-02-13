const std = @import("std");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const SessionData = @import("session_data.zig");

pub const Header = struct {
    content_len: usize,

    pub fn read_and_parse(allocator: std.mem.Allocator, reader: anytype) !Header {
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        const max_read = std.fmt.count("Content-Length: {}\r\n", .{std.math.maxInt(u64)});
        try reader.readUntilDelimiterArrayList(&list, '\n', max_read);
        _ = std.mem.indexOf(u8, list.items, "Content-Length") orelse return error.NoContentLength;
        const extracted = utils.extractInt(list.items) orelse return error.NoContentLength;
        const parsed_len = try std.fmt.parseInt(usize, extracted, 10);

        // read until the head body separator "\r\n"
        while (true) {
            const byte = try reader.readByte();
            if (byte == '\r' and try reader.readByte() == '\n') {
                break;
            }
        }

        return .{ .content_len = parsed_len };
    }
};

pub fn create_message(allocator: std.mem.Allocator, value: protocol.Object) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    try std.json.stringify(value, .{
        .emit_null_optional_fields = false,
    }, list.writer());

    var buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "Content-Length: {d}\r\n\r\n", .{list.items.len});
    try list.insertSlice(0, header);

    return list.toOwnedSlice();
}

pub fn message_exists(pipe: std.fs.File, allocator: std.mem.Allocator, timeout: u64) !bool {
    var poller = std.io.poll(allocator, enum { stdout }, .{
        .stdout = pipe,
    });
    defer poller.deinit();

    // return try poller.pollTimeout(timeout);
    const t = std.math.cast(i32, timeout) orelse std.math.maxInt(i32);
    return try std.posix.poll(&poller.poll_fds, t) > 0;
}

pub fn read_message(pipe: std.fs.File, allocator: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
    const reader = pipe.reader();
    const header = try Header.read_and_parse(allocator, reader);
    const message_content = try read_all(allocator, header, reader);
    defer allocator.free(message_content);

    const json_options = std.json.ParseOptions{ .ignore_unknown_fields = true };

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, message_content, json_options);
    errdefer parsed.deinit();

    if (parsed.value != .object) {
        return error.NotAnObject;
    }

    return parsed;
}

pub fn read_all(allocator: std.mem.Allocator, header: Header, reader: anytype) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    try list.ensureTotalCapacity(header.content_len);
    defer list.deinit();

    while (list.items.len < header.content_len) {
        const byte = reader.readByte() catch break;
        try list.append(byte);
    }

    return list.toOwnedSlice();
}

pub fn open_file_as_source_content(allocator: std.mem.Allocator, path: []const u8) !struct { SessionData.SourceID, SessionData.SourceContent } {
    std.debug.assert(std.fs.path.isAbsolute(path));

    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();
    return .{
        .{ .path = path },
        .{ .content = try file.readToEndAlloc(allocator, std.math.maxInt(u32)), .mime_type = null },
    };
}
