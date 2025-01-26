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
    var connection = Connection.init(gpa.allocator(), adapter);
    defer connection.deinit();

    try connection.adapter_spawn();

    const table = .{
        SessionData.handle_event_output,
        SessionData.handle_event_modules,
        SessionData.handle_event_terminated,
    };

    while (!window.shouldClose()) {
        connection.queue_messages(1) catch |err| {
            std.debug.print("{}\n", .{err});
        };

        inline for (table) |entry| {
            entry(&data, &connection) catch |err|
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
    const init_args = protocol.InitializeRequestArguments{
        .clientName = "unidep",
        .adapterID = "???",
    };
    const init_seq = try connection.send_init_request(init_args, .{});
    try connection.wait_for_response(init_seq);
    try connection.handle_init_response(init_seq);

    var extra = Object{};
    defer extra.deinit(connection.allocator);
    try extra.map.put(connection.allocator, "program", .{ .string = args.debugee });

    const launch_seq = try connection.send_launch_request(.{}, extra);
    try connection.wait_for_event("initialized");
    try connection.handle_initialized_event();

    // TODO: Send configurations here

    const config_seq = try connection.send_configuration_done_request(null, .{});

    try connection.wait_for_response(launch_seq);
    try connection.handle_launch_response(launch_seq);
    try connection.wait_for_response(config_seq);
    try connection.handle_configuration_done_response(config_seq);
}

pub const Args = struct {
    adapter: []const u8 = "",
    debugee: []const u8 = "",
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
