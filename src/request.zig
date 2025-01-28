const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig").SessionData;
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");

pub fn pause(connection: *Connection, thread_id: i32) !void {
    _ = try connection.queue_request(.pause, protocol.PauseArguments{
        .threadId = thread_id,
    }, .none);
}
