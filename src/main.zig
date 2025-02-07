const std = @import("std");
const glfw = @import("zglfw");
const protocol = @import("protocol.zig");
const io = @import("io.zig");
const utils = @import("utils.zig");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const Object = protocol.Object;
const time = std.time;
const ui = @import("ui.zig");
const log = std.log.scoped(.main);
const handlers = @import("handlers.zig");

pub fn main() !void {
    const args = try parse_args();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const window = try ui.init_ui(gpa.allocator());
    defer ui.deinit_ui(window);

    var data = SessionData.init(gpa.allocator());
    defer data.deinit();

    const adapter: []const []const u8 = &.{args.adapter};
    var connection = Connection.init(gpa.allocator(), adapter, args.debug_connection);
    defer connection.deinit();

    var callbacks = handlers.Callbacks.init(gpa.allocator());
    defer {
        for (callbacks.items) |cb| {
            if (cb.message) |m| m.deinit();
        }
        callbacks.deinit();
    }

    loop(window, &callbacks, &connection, &data, args);

    log.info("Window Closed", .{});
}

fn loop(window: *glfw.Window, callbacks: *handlers.Callbacks, connection: *Connection, data: *SessionData, args: Args) void {
    while (!window.shouldClose()) {
        while (true) {
            const ok = connection.queue_messages(1) catch |err| blk: {
                log.err("queue_messages: {}", .{err});
                break :blk false;
            };
            if (!ok) break;
        }

        handlers.handle_queued_events(callbacks, data, connection);
        handlers.send_queued_requests(connection);
        handlers.handle_queued_responses(data, connection);
        handlers.handle_callbacks(callbacks, data, connection);

        ui.ui_tick(window, callbacks, connection, data, args);
    }
}

pub const Args = struct {
    adapter: []const u8 = "",
    debugee: []const u8 = "",
    debug_connection: bool = false,
};
fn parse_args() !Args {
    if (std.os.argv.len == 1) {
        log.err("Must provide arguments", .{});
        std.process.exit(1);
    }

    var iter = std.process.ArgIterator.init();
    var result = Args{};
    _ = iter.skip();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--adapter")) {
            result.adapter = try get_arg_without_double_dash(&iter, error.MissingAdapterPath);
        } else if (std.mem.eql(u8, arg, "--debugee")) {
            result.debugee = try get_arg_without_double_dash(&iter, error.MissingDebugeePath);
        } else if (std.mem.eql(u8, arg, "--debug_connection")) {
            result.debug_connection = true;
        } else {
            log.err("Unknow arg {s}", .{arg});
            std.process.exit(1);
        }
    }

    return result;
}

fn get_arg_without_double_dash(iter: *std.process.ArgIterator, err: anyerror) ![]const u8 {
    const arg = iter.next() orelse return err;
    if (std.mem.startsWith(u8, arg, "--")) {
        return err;
    }

    return arg;
}
