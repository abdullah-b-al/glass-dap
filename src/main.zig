const std = @import("std");
const glfw = @import("zglfw");
const protocol = @import("protocol.zig");
const io = @import("io.zig");
const utils = @import("utils.zig");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig").SessionData;
const Object = protocol.Object;
const time = std.time;
const ui = @import("ui.zig");
const log = std.log.scoped(.main);

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

    loop(window, &connection, &data, args);

    log.info("Window Closed", .{});
}

fn loop(window: *glfw.Window, connection: *Connection, data: *SessionData, args: Args) void {
    while (!window.shouldClose()) {
        connection.queue_messages(1) catch |err| {
            std.debug.print("{}\n", .{err});
        };

        handle_queued_events(data, connection);
        send_queued_requests(connection);
        handle_queued_responses(data, connection);
        handle_callbacks(data, connection);

        ui.ui_tick(window, connection, data, args);
    }
}

fn handle_callbacks(data: *SessionData, connection: *Connection) void {
    for (connection.handled_responses.items) |resp| {
        var i: usize = 0;
        while (i < data.callbacks.items.len) {
            const cb = data.callbacks.items[i];
            const call_if = switch (cb.call_if) {
                .success, .fail => resp.success,
                .always => true,
            };

            const when_to_call = switch (cb.when_to_call) {
                .request_seq => |wanted| wanted == resp.request_seq,
                .response => |wanted| wanted == resp.command,
                .any => true,
            };

            if (call_if and when_to_call) {
                cb.function(data, connection, cb.message);
                _ = data.callbacks.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

fn send_queued_requests(connection: *Connection) void {
    var i: usize = 0;
    while (i < connection.queued_requests.items.len) {
        const request = connection.queued_requests.items[i];
        if (dependency_satisfied(connection.*, request)) {
            defer _ = connection.queued_requests.orderedRemove(i);
            connection.send_request(request) catch |err| switch (err) {
                error.OutOfMemory,
                error.NoSpaceLeft,

                error.NoDevice,
                error.SystemResources,
                error.AccessDenied,
                error.Unexpected,
                error.ProcessNotFound,
                error.InputOutput,
                error.OperationAborted,
                error.BrokenPipe,
                error.ConnectionResetByPeer,
                error.WouldBlock,
                error.LockViolation,
                error.DiskQuota,
                error.FileTooBig,
                error.DeviceBusy,
                error.InvalidArgument,
                error.NotOpenForWriting,

                error.AdapterNotDoneInitializing,
                error.AdapterNotSpawned,
                error.AdapterDoesNotSupportRequest,
                => {
                    log.err("{}\n", .{err});
                },
            };
        } else {
            i += 1;
        }
    }
}

fn handle_queued_responses(data: *SessionData, connection: *Connection) void {
    if (connection.expected_responses.items.len == 0) return;

    var i: usize = 0;
    while (i < connection.expected_responses.items.len) {
        const resp = connection.expected_responses.items[i];

        if (data.handle_response(connection, resp.command, resp.request_seq)) {
            _ = connection.expected_responses.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn handle_queued_events(data: *SessionData, connection: *Connection) void {
    var i: usize = 0;
    while (i < connection.events.items.len) {
        const parsed = connection.events.items[i];
        const value = utils.get_value(parsed.value, "event", .string) orelse @panic("Only event should be here");
        const event = utils.string_to_enum(Connection.Event, value) orelse {
            log.err("Unknown event {s}", .{value});
            return;
        };
        const handled = data.handle_event(connection, event) catch |err|
            switch (err) {
            error.EventDoesNotExist => unreachable,
            else => blk: {
                log.err("{}", .{err});
                break :blk true; // ignore
            },
        };

        if (handled) {
            i += 1;
        }
    }
}

fn dependency_satisfied(connection: Connection, to_send: Connection.Request) bool {
    switch (to_send.depends_on) {
        .event => |event| {
            for (connection.handled_events.items) |item| {
                if (item == event) return true;
            }
        },
        .seq => |seq| {
            for (connection.handled_responses.items) |item| {
                if (item.request_seq == seq) return true;
            }
        },
        .response => |command| {
            for (connection.handled_responses.items) |item| {
                if (item.command == command) return true;
            }
        },
        .none => return true,
    }

    return false;
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
