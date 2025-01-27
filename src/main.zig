const std = @import("std");
const protocol = @import("protocol.zig");
const io = @import("io.zig");
const utils = @import("utils.zig");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig").SessionData;
const Object = protocol.Object;
const time = std.time;
const ui = @import("ui.zig");

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

    const events = [_]Connection.Event{
        .output,
        .module,
        .terminated,
    };

    while (!window.shouldClose()) {
        connection.queue_messages(1) catch |err| {
            std.debug.print("{}\n", .{err});
        };

        for (events) |event| {
            data.handle_event(&connection, event) catch |err|
                switch (err) {
                error.EventDoseNotExist => {},
                else => {
                    std.log.err("{}", .{err});
                },
            };
        }

        ui.ui_tick(window, &connection, &data, args);
    }
    std.log.info("Window Closed", .{});
}

pub fn begin_debug_sequence(connection: *Connection, args: Args) !void {
    // send and respond to initialize
    // send launch or attach
    // when the adapter is ready it'll send a initialized event
    // send configuration
    // send configuration done
    // respond to launch or attach
    const init_args = protocol.InitializeRequestArguments{
        .clientName = "unidep",
        .adapterID = "???",
    };

    if (connection.state == .not_spawned) {
        try connection.adapter_spawn();
    }

    const init_seq = try connection.send_request_init(init_args);
    try connection.wait_for_response(init_seq);
    try connection.handle_response_init(init_seq);

    const launch_seq = blk: {
        var extra = Object{};
        defer extra.deinit(connection.allocator);
        try extra.map.put(connection.allocator, "program", .{ .string = args.debugee });
        break :blk try connection.send_request_launch(.{}, extra);
    };
    const inited_seq = try connection.wait_for_event("initialized");
    connection.handle_event_initialized(inited_seq);

    // TODO: Send configurations here

    const config_seq = try connection.send_request_configuration_done(null, .{});
    try connection.wait_for_response(config_seq);
    try connection.handle_response_configuration_done(config_seq);

    try connection.wait_for_response(launch_seq);
    try connection.handle_response_launch(launch_seq);
}

pub const Args = struct {
    adapter: []const u8 = "",
    debugee: []const u8 = "",
    debug_connection: bool = false,
};
fn parse_args() !Args {
    if (std.os.argv.len == 1) {
        std.log.err("Must provide arguments", .{});
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
            std.log.err("Unknow arg {s}", .{arg});
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
