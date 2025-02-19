const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const ui = @import("ui.zig");
const handlers = @import("handlers.zig");
const config = @import("config.zig");
const Callbacks = handlers.Callbacks;
const Dependency = Connection.Dependency;

pub fn begin_session(arena: std.mem.Allocator, connection: *Connection, data: *SessionData) !bool {
    // send and respond to initialize
    // send launch or attach
    // when the adapter is ready it'll send a initialized event
    // send configuration
    // send configuration done
    // respond to launch or attach

    switch (connection.state) {
        .launched, .attached => return true,
        else => {},
    }

    if (get_launch_config() == null) {
        ui.state.ask_for_launch_config = true;
        return false;
    }

    const static = struct {
        var init_done = false;
        var launch_done = false;
        var launch_when = Dependency.When.after_queueing;
    };

    const init_args = protocol.InitializeRequestArguments{
        .clientName = "thabit",
        .adapterID = "???",
        .columnsStartAt1 = false,
        .linesStartAt1 = false,
    };

    connection.adapter_spawn() catch |err| switch (err) {
        error.AdapterAlreadySpawned => {},
        else => return err,
    };

    if (!static.init_done) {
        try connection.queue_request_init(init_args, .none);
        static.init_done = true;
    }
    if (!static.launch_done) {
        launch(arena, connection, .{ .dep = .{ .response = .initialize }, .handled_when = static.launch_when }) catch |err| switch (err) {
            error.NoLaunchConfig => unreachable,
            else => return err,
        };
        static.launch_done = true;
    }

    data.begin_session();

    // TODO: Send configurations here

    _ = try connection.queue_request_configuration_done(
        null,
        .{},
        .{ .dep = .{ .event = .initialized }, .handled_when = .any },
    );

    return true;
}

pub fn end_session(connection: *Connection, how: enum { terminate, disconnect }) !void {
    switch (connection.state) {
        .initialized,
        .partially_initialized,
        .initializing,
        .spawned,
        => return error.SessionNotStarted,

        .died, .not_spawned => return error.AdapterNotSpawned,

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
    const l, const i = get_launch_config() orelse return error.NoLaunchConfig;

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
pub fn get_thread_state(connection: *Connection, thread_id: SessionData.ThreadID) !void {
    _ = try connection.queue_request(
        .stackTrace,
        protocol.StackTraceArguments{ .threadId = @intFromEnum(thread_id) },
        .none,
        .{ .stack_trace = .{
            .thread_id = thread_id,
            .request_scopes = true,
            .request_variables = true,
        } },
    );
}

pub fn scopes(connection: *Connection, thread_id: SessionData.ThreadID, frame_id: SessionData.FrameID, request_variables: bool) !void {
    _ = try connection.queue_request(
        .scopes,
        protocol.ScopesArguments{ .frameId = @intFromEnum(frame_id) },
        .none,
        .{ .scopes = .{
            .thread_id = thread_id,
            .frame_id = frame_id,
            .request_variables = request_variables,
        } },
    );
}

pub fn variables(connection: *Connection, thread_id: SessionData.ThreadID, reference: SessionData.VariableReference) !void {
    _ = try connection.queue_request(
        .variables,
        protocol.VariablesArguments{ .variablesReference = @intFromEnum(reference) },
        .none,
        .{ .variables = .{
            .thread_id = thread_id,
            .variables_reference = reference,
        } },
    );
}

pub fn next(callbacks: *Callbacks, data: SessionData, connection: *Connection, granularity: protocol.SteppingGranularity) void {
    var iter = UnlockedThreadsIterator.init(data);
    while (iter.next()) |thread| {
        const arg = protocol.NextArguments{
            .threadId = @intFromEnum(thread.id),
            .singleThread = true,
            .granularity = granularity,
        };

        _ = connection.queue_request(.next, arg, .none, .{ .next = .{
            .thread_id = thread.id,
            .request_stack_trace = false,
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
        switch (thread.state) {
            .continued => continue,
            .stopped, .unknown => {},
        }

        const args = protocol.ContinueArguments{
            .threadId = @intFromEnum(thread.id),
            .singleThread = true,
        };

        _ = connection.queue_request(.@"continue", args, Dependency.none, .no_data) catch return;
    }
}

pub fn pause(data: SessionData, connection: *Connection) void {
    var iter = UnlockedThreadsIterator.init(data);
    while (iter.next()) |thread| {
        switch (thread.state) {
            .stopped => continue,
            .continued, .unknown => {},
        }

        _ = connection.queue_request(.pause, protocol.PauseArguments{
            .threadId = @intFromEnum(thread.id),
        }, Dependency.none, .no_data) catch return;

        _ = connection.queue_request(
            .stackTrace,
            protocol.StackTraceArguments{ .threadId = @intFromEnum(thread.id) },
            .{ .dep = .{ .response = .threads }, .handled_when = .after_queueing },
            .{ .stack_trace = .{
                .thread_id = thread.id,
                .request_scopes = false,
                .request_variables = false,
            } },
        ) catch return;
    }
}

pub fn set_breakpoints(data: SessionData, connection: *Connection, source_id: SessionData.SourceID) !void {
    const source = data.get_source(source_id) orelse return error.NoSource;
    const breakpoints = data.source_breakpoints.getPtr(source_id) orelse return;

    try connection.queue_request(.setBreakpoints, protocol.SetBreakpointsArguments{
        .source = source,
        .breakpoints = breakpoints.values(),
        .lines = null,
        .sourceModified = null,
    }, .none, .{ .set_breakpoints = .{ .source_id = source_id } });
}

pub fn set_variable(connection: *Connection, thread_id: SessionData.ThreadID, reference: SessionData.VariableReference, name: []const u8, value: []const u8, has_evaluate_name: bool) !void {
    const use_expression =
        connection.adapter_capabilities.support.contains(.supportsSetExpression) and
        connection.adapter_capabilities.support.contains(.supportsSetVariable) and
        has_evaluate_name;

    if (use_expression) {
        // TODO: use set expression when implemented
    } else {
        try protocol_set_variable(connection, thread_id, reference, name, value);
    }
}

fn protocol_set_variable(connection: *Connection, thread_id: SessionData.ThreadID, reference: SessionData.VariableReference, name: []const u8, value: []const u8) !void {
    _ = try connection.queue_request(.setVariable, protocol.SetVariableArguments{
        .variablesReference = @intFromEnum(reference),
        .name = name,
        .value = value,
        .format = null,
    }, .none, .{
        .set_variable = .{
            .thread_id = thread_id,
            .reference = reference,
            .name = name,
        },
    });
}

////////////////////////////////////////////////////////////////////////////////
// Helpers

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

fn get_launch_config() ?struct { config.Launch, usize } {
    const l = config.launch orelse return null;
    const i = ui.state.launch_config_index orelse return null;
    if (i >= l.configurations.len) {
        ui.state.launch_config_index = null;
        return null;
    }

    return .{ l, i };
}
