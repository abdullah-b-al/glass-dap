const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const ui = @import("ui.zig");
const handlers = @import("handlers.zig");
const config = @import("config.zig");
const Callbacks = handlers.Callbacks;

pub fn begin_session(arena: std.mem.Allocator, connection: *Connection) !void {
    // send and respond to initialize
    // send launch or attach
    // when the adapter is ready it'll send a initialized event
    // send configuration
    // send configuration done
    // respond to launch or attach
    const init_args = protocol.InitializeRequestArguments{
        .clientName = "thabit",
        .adapterID = "???",
        .columnsStartAt1 = false,
        .linesStartAt1 = false,
    };

    if (connection.state == .not_spawned) {
        try connection.adapter_spawn();
    }

    const init_seq = try connection.queue_request_init(init_args, .none);
    launch(arena, connection, .{ .seq = init_seq }) catch |err| switch (err) {
        error.NoLaunchConfig => {
            ui.state.ask_for_launch_config = true;
            return;
        },
        else => return err,
    };

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
                    .no_data,
                ),

                .disconnect => _ = try connection.queue_request(
                    .disconnect,
                    protocol.DisconnectArguments{
                        .restart = false,
                        .terminateDebuggee = null,
                        .suspendDebuggee = null,
                    },
                    .none,
                    .no_data,
                ),
            }
        },
    }
}

pub fn launch(arena: std.mem.Allocator, connection: *Connection, dependency: Connection.Dependency) !void {
    const l = config.launch orelse return error.NoLaunchConfig;
    const i = ui.state.launch_config_index orelse return error.NoLaunchConfig;
    if (i >= l.configurations.len) {
        ui.state.launch_config_index = null;
        return error.NoLaunchConfig;
    }

    var extra = protocol.Object{};

    const object = l.configurations[i];
    var iter = object.map.iterator();
    while (iter.next()) |entry| {
        const value = try utils.to_protocol_value(arena, entry.value_ptr.*);
        try extra.map.put(arena, entry.key_ptr.*, value);
    }

    _ = try connection.queue_request_launch(.{}, extra, dependency);
}

// Causes a chain of requests to get the state
pub fn get_thread_state(connection: *Connection, thread_id: i32) !void {
    _ = try connection.queue_request(
        .stackTrace,
        protocol.StackTraceArguments{ .threadId = thread_id },
        .none,
        .{ .stack_trace = .{
            .thread_id = thread_id,
            .request_scopes = true,
            .request_variables = true,
        } },
    );
}

pub fn next(callbacks: *Callbacks, data: SessionData, connection: *Connection, granularity: protocol.SteppingGranularity) void {
    var iter = UnlockedThreadsIterator.init(data);
    while (iter.next()) |thread| {
        const arg = protocol.NextArguments{
            .threadId = thread.id,
            .singleThread = true,
            .granularity = granularity,
        };

        _ = connection.queue_request(.next, arg, .none, .{ .next = .{
            .thread_id = thread.id,
            .request_stack_trace = true,
            .request_scopes = false,
            .request_variables = false,
        } }) catch return;
    }

    const static = struct {
        fn func(_: *SessionData, _: *Connection, _: ?Connection.RawMessage) void {
            ui.state.scroll_to_active_line = true;
            ui.state.update_active_source_to_top_of_stack = true;
        }
    };

    handlers.callback(callbacks, .success, .{ .response = .stackTrace }, null, static.func) catch return;
}

pub fn continue_threads(data: SessionData, connection: *Connection) void {
    var iter = UnlockedThreadsIterator.init(data);
    while (iter.next()) |thread| {
        const args = protocol.ContinueArguments{
            .threadId = thread.id,
            .singleThread = true,
        };

        _ = connection.queue_request(.@"continue", args, .none, .no_data) catch return;
    }
}

pub fn pause(data: SessionData, connection: *Connection) void {
    var iter = UnlockedThreadsIterator.init(data);
    while (iter.next()) |thread| {
        _ = connection.queue_request(.pause, protocol.PauseArguments{
            .threadId = thread.id,
        }, .none, .no_data) catch return;

        _ = connection.queue_request(
            .stackTrace,
            protocol.StackTraceArguments{ .threadId = thread.id },
            .{ .response = .threads },
            .{ .stack_trace = .{
                .thread_id = thread.id,
                .request_scopes = false,
                .request_variables = false,
            } },
        ) catch return;
    }
}

pub const UnlockedThreadsIterator = struct {
    iter: SessionData.Threads.Iterator,

    pub fn init(data: SessionData) UnlockedThreadsIterator {
        return .{ .iter = data.threads.iterator() };
    }

    pub fn next(self: *UnlockedThreadsIterator) ?SessionData.Thread {
        while (self.iter.next()) |entry| {
            if (entry.value_ptr.unlocked) {
                return entry.value_ptr.*;
            }
        }

        return null;
    }
};
