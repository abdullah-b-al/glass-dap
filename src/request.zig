const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");

pub fn begin_session(connection: *Connection, debugee: []const u8) !void {
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

    const init_seq = try connection.queue_request_init(init_args, .none);

    {
        var extra = protocol.Object{};
        defer extra.deinit(connection.allocator);
        try extra.map.put(connection.allocator, "program", .{ .string = debugee });
        _ = try connection.queue_request_launch(.{}, extra, .{ .seq = init_seq });
    }

    // TODO: Send configurations here

    _ = try connection.queue_request_configuration_done(null, .{}, .{ .event = .initialized });
}

pub fn end_session(connection: *Connection, how: enum { terminate, disconnect }) !void {
    switch (connection.state) {
        .initialized,
        .partially_initialized,
        .initializing,
        .spawned,
        => return error.SessionNotStarted,

        .not_spawned => return error.AdapterNotSpawned,

        .attached => @panic("TODO"),
        .launched => {
            switch (how) {
                .terminate => _ = try connection.queue_request(
                    .terminate,
                    protocol.TerminateArguments{
                        .restart = false,
                    },
                    .none,
                    null,
                ),

                .disconnect => _ = try connection.queue_request(
                    .disconnect,
                    protocol.DisconnectArguments{
                        .restart = false,
                        .terminateDebuggee = null,
                        .suspendDebuggee = null,
                    },
                    .none,
                    null,
                ),
            }
        },
    }
}
