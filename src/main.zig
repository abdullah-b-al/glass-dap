const std = @import("std");
const protocol = @import("protocol.zig");
const io = @import("io.zig");
const utils = @import("utils.zig");
const Session = @import("session.zig");
const Object = protocol.Object;
const time = std.time;
const ui = @import("ui.zig");

pub fn main() !void {
    const args = try parse_args();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const window = try ui.init_ui(gpa.allocator());
    defer ui.deinit_ui(window);

    const adapter: []const []const u8 = &.{args.adapter};
    var session = Session.init(gpa.allocator(), adapter);

    try session.adapter_spawn();
    try begin_debug_sequence(&session, args);

    while (!window.shouldClose()) {
        session.queue_messages(1) catch |err| {
            std.debug.print("{}\n", .{err});
        };

        session.handle_output_event() catch |err|
            switch (err) {
            error.EventDoseNotExist => {},
        };
        session.handle_module_event() catch |err| switch (err) {
            error.EventDoseNotExist => {},
        };
        ui.ui_tick(window, &session);
    }
    std.log.info("Window Closed", .{});
}

fn begin_debug_sequence(session: *Session, args: Args) !void {
    const init_args = protocol.InitializeRequestArguments{
        .clientName = "unidep",
        .adapterID = "???",
    };
    const init_seq = try session.send_init_request(init_args, .{});
    try session.wait_for_response(init_seq);
    try session.handle_init_response(init_seq);

    var extra = Object{};
    defer extra.deinit(session.allocator);
    try extra.map.put(session.allocator, "program", .{ .string = args.debugee });

    const launch_seq = try session.send_launch_request(.{}, extra);
    try session.wait_for_event("initialized");
    try session.handle_initialized_event();

    // TODO: Send configurations here

    const config_seq = try session.send_configuration_done_request(null, .{});

    try session.wait_for_response(launch_seq);
    try session.handle_launch_response(launch_seq);
    try session.wait_for_response(config_seq);
    try session.handle_configuration_done_response(config_seq);
}

const Args = struct {
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
