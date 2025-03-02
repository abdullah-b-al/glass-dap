const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const config = @import("config.zig");
const Callbacks = session.Callbacks;
const Dependency = Connection.Dependency;
const log = std.log.scoped(.request);

pub const client_name = "glass-dap";

pub fn initialize_arguments(connection: *const Connection) protocol.InitializeRequestArguments {
    std.debug.assert(connection.adapter.process != null);
    return protocol.InitializeRequestArguments{
        .clientID = client_name,
        .clientName = client_name,
        .adapterID = connection.adapter.id,
        .locale = "en-US",
        .pathFormat = .path,
        .columnsStartAt1 = false,
        .linesStartAt1 = false,

        .supportsVariableType = false,
        .supportsVariablePaging = false,
        .supportsRunInTerminalRequest = false,
        .supportsMemoryReferences = false,
        .supportsProgressReporting = false,
        .supportsInvalidatedEvent = false,
        .supportsMemoryEvent = false,
        .supportsArgsCanBeInterpretedByShell = false,
        .supportsStartDebuggingRequest = false,
        .supportsANSIStyling = false,
    };
}

var begin_session_state: BeginSessionState = .begin;
const BeginSessionState = enum {
    begin,
    init_and_launch,
    config_done,
    done,

    pub fn next(s: *@This()) void {
        s.* = switch (s.*) {
            .begin => .init_and_launch,
            .init_and_launch => .config_done,
            .config_done => .done,
            .done => .done,
        };
    }
};

pub fn begin_session(arena: std.mem.Allocator, connection: *Connection, data: *SessionData) !bool {
    // send and respond to initialize
    // send launch or attach
    // when the adapter is ready it'll send a initialized event
    // send configuration
    // send configuration done
    // respond to launch or attach

    if (connection.adapter.process == null and ui.state.adapter_name.len > 0) {
        errdefer {
            ui.state.adapter_name.clear();
        }

        const id, const argv = get_id_and_argv() orelse return true;
        try connection.adapter.set(id, argv);
    }

    if (connection.adapter.process == null or ui.state.adapter_name.len == 0) {
        ui.state.ask_for_adapter = true;
        return false;
    }

    switch (data.status) {
        .terminated, .not_running => {},
        .running, .stopped => {
            switch (connection.adapter.state) {
                .launched, .attached => {
                    return true;
                },
                else => {},
            }
        },
    }

    switch (begin_session_state) {
        .begin, .init_and_launch => {
            if (get_launch_config() == null) {
                ui.state.ask_for_launch_config = true;
                return false;
            }
        },
        .done, .config_done => {},
    }

    connection.adapter.spawn() catch |err| switch (err) {
        error.AdapterAlreadySpawned => {},
        else => return err,
    };

    switch (begin_session_state) {
        .begin => {
            session.begin(connection, data);
        },
        .init_and_launch => {
            try connection.queue_request_init(initialize_arguments(connection), .none);
            launch(arena, connection, .{ .dep = .{ .response = .initialize }, .handled_when = .after_queueing }) catch |err| switch (err) {
                error.NoLaunchConfig => unreachable,
                else => return err,
            };
        },

        // TODO: send configurations

        .config_done => {
            _ = try connection.queue_request_configuration_done(
                null,
                .{},
                .{ .dep = .{ .event = .initialized }, .handled_when = .any },
            );
        },
        .done => {},
    }

    begin_session_state.next();
    return begin_session_state == .done;
}

pub fn end_session(connection: *Connection, how: enum { terminate, disconnect }) !void {
    switch (connection.adapter.state) {
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

    begin_session_state = .begin;
}

pub fn launch(arena: std.mem.Allocator, connection: *Connection, dependency: Connection.Dependency) !void {
    const launch_config = get_launch_config() orelse return error.NoLaunchConfig;

    var extra = protocol.Object{};

    const object = launch_config;
    var iter = object.map.iterator();
    while (iter.next()) |entry| {
        const value = try utils.to_protocol_value(arena, entry.value_ptr.*);
        try extra.map.put(arena, entry.key_ptr.*, value);
    }

    _ = try connection.queue_request_launch(.{}, extra, dependency);

    ui.state.launch_config = null;
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

pub fn default_stack_trace_args(thread_id: SessionData.ThreadID) protocol.StackTraceArguments {
    return .{
        .threadId = @intFromEnum(thread_id),
        .startFrame = 0, // all
        .levels = std.math.maxInt(u16), // some adapters don't want null or 0
    };
}
pub fn stack_trace(connection: *Connection, thread_id: SessionData.ThreadID) !void {
    _ = try connection.queue_request(
        .stackTrace,
        default_stack_trace_args(thread_id),
        .none,
        .{ .stack_trace = .{
            .thread_id = thread_id,
            .request_scopes = false,
            .request_variables = false,
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

pub fn default_variables_args(reference: SessionData.VariableReference) protocol.VariablesArguments {
    return .{
        .variablesReference = @intFromEnum(reference),
        // all variables
        .start = 0,
        .count = 0,
    };
}

pub fn variables(connection: *Connection, thread_id: SessionData.ThreadID, reference: SessionData.VariableReference) !void {
    _ = try connection.queue_request(
        .variables,
        default_variables_args(reference),
        .none,
        .{ .variables = .{
            .thread_id = thread_id,
            .variables_reference = reference,
        } },
    );
}

const Step = enum {
    next,
    in,
    out,
};

pub fn step(callbacks: *Callbacks, data: SessionData, connection: *Connection, step_kind: Step, granularity: protocol.SteppingGranularity) void {
    const static = struct {
        var wait = false;
        fn stack_trace(_: *SessionData, _: *Connection, _: ?Connection.RawMessage) void {
            ui.state.scroll_to_active_line = true;
            ui.state.update_active_source_to_top_of_stack = true;
        }

        fn step(_: *SessionData, _: *Connection, _: ?Connection.RawMessage) void {
            wait = false;
        }
    };

    if (static.wait) {
        return;
    }

    switch (step_kind) {
        .next => next(data, connection, granularity),
        .in => step_in(data, connection, granularity),
        .out => step_out(data, connection, granularity),
    }

    static.wait = true;
    session.callback(callbacks, .success, .{ .response = .stackTrace }, null, static.stack_trace) catch return;
    const command: Connection.Command = switch (step_kind) {
        .next => .next,
        .in => .stepIn,
        .out => .stepOut,
    };
    session.callback(callbacks, .always, .{ .response = command }, null, static.step) catch return;
}
fn step_in(data: SessionData, connection: *Connection, granularity: protocol.SteppingGranularity) void {
    var iter = SelectedThreadsIterator.init(data, connection);
    while (iter.next()) |thread| {
        const arg = protocol.StepInArguments{
            .threadId = @intFromEnum(thread.id),
            .singleThread = true,
            .targetId = null,
            .granularity = granularity,
        };

        _ = connection.queue_request(.stepIn, arg, .none, .no_data) catch return;
    }
}
fn step_out(data: SessionData, connection: *Connection, granularity: protocol.SteppingGranularity) void {
    var iter = SelectedThreadsIterator.init(data, connection);
    while (iter.next()) |thread| {
        const arg = protocol.StepOutArguments{
            .threadId = @intFromEnum(thread.id),
            .singleThread = true,
            .granularity = granularity,
        };

        _ = connection.queue_request(.stepOut, arg, .none, .no_data) catch return;
    }
}

pub fn next(data: SessionData, connection: *Connection, granularity: protocol.SteppingGranularity) void {
    var iter = SelectedThreadsIterator.init(data, connection);
    while (iter.next()) |thread| {
        const arg = protocol.NextArguments{
            .threadId = @intFromEnum(thread.id),
            .singleThread = true,
            .granularity = granularity,
        };

        _ = connection.queue_request(.next, arg, .none, .no_data) catch return;
    }
}

pub fn continue_threads(data: SessionData, connection: *Connection) void {
    var iter = SelectedThreadsIterator.init(data, connection);
    while (iter.next()) |thread| {
        switch (thread.status) {
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
    var iter = SelectedThreadsIterator.init(data, connection);
    while (iter.next()) |thread| {
        switch (thread.status) {
            .stopped => continue,
            .continued, .unknown => {},
        }

        _ = connection.queue_request(.pause, protocol.PauseArguments{
            .threadId = @intFromEnum(thread.id),
        }, Dependency.none, .no_data) catch return;

        _ = connection.queue_request(
            .stackTrace,
            default_stack_trace_args(thread.id),
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

pub fn set_data_breakpoints(data: *const SessionData, connection: *Connection) !void {
    try connection.queue_request(
        .setDataBreakpoints,
        protocol.SetDataBreakpointsArguments{ .breakpoints = data.data_breakpoints.keys() },
        .none,
        .no_data,
    );
}

pub fn data_breakpoint_info_variable(
    connection: *Connection,
    name: []const u8,
    thread_id: SessionData.ThreadID,
    reference: SessionData.VariableReference,
) !void {
    try connection.queue_request(.dataBreakpointInfo, protocol.DataBreakpointInfoArguments{
        .variablesReference = @intFromEnum(reference),
        .name = name,
        .frameId = null,
        .bytes = null,
        .asAddress = null,
        .mode = null,
    }, .none, .{
        .data_breakpoint_info = .{
            .name = name,
            .thread_id = thread_id,
            .reference = reference,
            .frame_id = null,
        },
    });
}

pub fn set_variable(
    connection: *Connection,
    thread_id: SessionData.ThreadID,
    reference: SessionData.VariableReference,
    frame_id: SessionData.FrameID,
    parent_name: []const u8,
    name: []const u8,
    value: []const u8,
    has_evaluate_name: bool,
) !void {
    const use_expression =
        connection.adapter_capabilities.support.contains(.supportsSetExpression) and
        connection.adapter_capabilities.support.contains(.supportsSetVariable) and
        has_evaluate_name;

    if (use_expression) {
        try set_expression(connection, thread_id, reference, parent_name, name, value, frame_id);
    } else {
        try protocol_set_variable(connection, thread_id, reference, name, value);
    }
}

pub fn set_expression(
    connection: *Connection,
    thread_id: SessionData.ThreadID,
    reference: SessionData.VariableReference,
    parent_name: []const u8,
    name: []const u8,
    value: []const u8,
    frame_id: SessionData.FrameID,
) !void {
    const expression = try utils.join_variables(ui.state.arena(), parent_name, name);

    try connection.queue_request(
        .setExpression,
        protocol.SetExpressionArguments{
            .expression = expression,
            .value = value,
            .frameId = @intFromEnum(frame_id),
            .format = null,
        },
        .none,
        .{ .set_expression = .{
            .thread_id = thread_id,
            .reference = reference,
            .name = name,
        } },
    );
}

fn protocol_set_variable(
    connection: *Connection,
    thread_id: SessionData.ThreadID,
    reference: SessionData.VariableReference,
    name: []const u8,
    value: []const u8,
) !void {
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

pub const SelectedThreadsIterator = struct {
    iter: SessionData.Threads.Iterator,
    connection: *const Connection,

    pub fn init(data: SessionData, connection: *const Connection) SelectedThreadsIterator {
        return .{ .iter = data.threads.iterator(), .connection = connection };
    }

    pub fn next(self: *SelectedThreadsIterator) ?SessionData.Thread {
        while (self.iter.next()) |entry| {
            if (entry.value_ptr.selected) {
                return entry.value_ptr.*;
            }
        }

        return null;
    }
};

fn get_launch_config() ?config.Object {
    const conf = ui.state.launch_config orelse return null;
    for (config.app.projects.keys(), config.app.projects.values()) |project, configs| {
        if (std.mem.eql(u8, project, conf.project.slice())) {
            if (conf.index >= configs.items.len) {
                ui.state.launch_config = null;
            } else {
                return configs.items[conf.index];
            }
        }
    }

    return null;
}

fn get_id_and_argv() ?struct { []const u8, []const []const u8 } {
    const entries = config.app.adapters.get(ui.state.adapter_name.slice()) orelse {
        log.err("Could not get adapter config from ui widget", .{});
        return null;
    };

    const id = blk: {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, "id")) {
                switch (entry.value) {
                    .string => |string| break :blk string,
                    else => {},
                }
            }
        }

        break :blk "";
    };

    const argv = blk: {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.key, "command")) {
                switch (entry.value) {
                    .string_array => |array| break :blk array,
                    else => {},
                }
            }
        }

        return null;
    };

    return .{ id, argv };
}
