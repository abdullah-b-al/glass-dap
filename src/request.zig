const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const ui = @import("ui.zig");
const session = @import("session.zig");
const config = @import("config.zig");
const Callbacks = session.Callbacks;
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
    wait,
    begin,
    init_and_launch,
    waiting_for_next_main_loop_tick,
    launch,
    config_done,
    done,
};

pub fn begin_session(arena: std.mem.Allocator, callbacks: *Callbacks, connection: *Connection, data: *SessionData) !enum { done, not_done } {
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

        const id, const argv = get_id_and_argv() orelse return .done;
        try connection.adapter.set(id, argv);
    }

    if (connection.adapter.process == null or ui.state.adapter_name.len == 0) {
        ui.state.ask_for_adapter = true;
        return .not_done;
    }

    switch (data.status) {
        .terminated, .not_running => {},
        .running, .stopped => {
            switch (connection.adapter.debuggee) {
                .launched, .attached => {
                    return .done;
                },
                .none => {},
            }
        },
    }

    switch (begin_session_state) {
        .waiting_for_next_main_loop_tick,
        .wait,
        => {},
        .begin, .init_and_launch, .launch => {
            if (get_launch_config() == null) {
                ui.state.ask_for_launch_config = true;
                return .not_done;
            }
        },
        .done, .config_done => {},
    }

    connection.adapter.spawn() catch |err| switch (err) {
        error.AdapterAlreadySpawned => {},
        else => return err,
    };

    const static = struct {
        pub fn goto_launch(_: *SessionData, _: *Connection) void {
            begin_session_state = .launch;
        }
        pub fn config_done(_: *SessionData, _: *Connection) void {
            begin_session_state = .config_done;
        }
    };

    switch (begin_session_state) {
        .wait => {},
        .waiting_for_next_main_loop_tick => {
            begin_session_state = .config_done;
        },

        .begin => {
            session.begin(connection, data);
            begin_session_state = .init_and_launch;
        },

        .init_and_launch => {
            try connection.queue_request_init(initialize_arguments(connection));
            begin_session_state = .wait;
            try session.callback(callbacks, .always, .{ .response = .initialize }, static.goto_launch);
        },

        .launch => {
            launch(arena, callbacks, connection) catch |err| switch (err) {
                error.NoLaunchConfig => unreachable,
                else => return err,
            };

            if (connection.adapter.state == .initialized) {
                begin_session_state = .config_done;
            } else {
                // by the next main loop tick the launch request would have been
                // sent and responded to
                begin_session_state = .waiting_for_next_main_loop_tick;
            }
        },

        // TODO: send configurations

        .config_done => {
            _ = try connection.queue_request_configuration_done(null, .{});
            begin_session_state = .done;
        },

        .done => begin_session_state = .done,
    }

    return if (begin_session_state == .done) return .done else .not_done;
}

pub fn end_session(connection: *Connection, how: enum { terminate, disconnect }) !void {
    switch (connection.adapter.debuggee) {
        .none => return error.SessionNotStarted,
        .attached, .launched => {},
    }
    switch (connection.adapter.state) {
        .partially_initialized,
        .initializing,
        .spawned,
        => return error.SessionNotStarted,

        .initialized => {},

        .died, .not_spawned => return error.AdapterNotSpawned,
    }

    switch (connection.adapter.debuggee) {
        .attached => @panic("TODO"),
        .launched => {
            switch (how) {
                .terminate => _ = try connection.queue_request(
                    .terminate,
                    protocol.TerminateArguments{
                        .restart = false,
                    },
                    .no_data,
                ),

                .disconnect => _ = try connection.queue_request(
                    .disconnect,
                    protocol.DisconnectArguments{
                        .restart = false,
                        .terminateDebuggee = null,
                        .suspendDebuggee = null,
                    },
                    .no_data,
                ),
            }
        },
        .none => {},
    }

    begin_session_state = .begin;
}

pub fn launch(arena: std.mem.Allocator, callbacks: *Callbacks, connection: *Connection) !void {
    const launch_config = get_launch_config() orelse return error.NoLaunchConfig;

    var extra = protocol.Object{};

    const object = launch_config;
    var iter = object.map.iterator();
    while (iter.next()) |entry| {
        const value = try utils.to_protocol_value(arena, entry.value_ptr.*);
        try extra.map.put(arena, entry.key_ptr.*, value);
    }

    _ = try connection.queue_request_launch(.{}, extra);

    session.callback(callbacks, .always, .{ .response = .launch }, struct {
        fn func(_: *SessionData, _: *Connection) void {
            ui.state.launch_config = null;
        }
    }.func) catch {
        ui.state.launch_config = null;
    };
}

// Causes a chain of requests to get the state
pub fn get_thread_state(connection: *Connection, thread_id: SessionData.ThreadID) !void {
    _ = try connection.queue_request(
        .stackTrace,
        protocol.StackTraceArguments{ .threadId = @intFromEnum(thread_id) },
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
        .{ .variables = .{
            .thread_id = thread_id,
            .variables_reference = reference,
        } },
    );
}

pub const EvaluateContext = enum {
    watch,
    repl,
    hover,
    clipboard,
    variables,
};
pub fn evaluate(connection: *Connection, thread_id: SessionData.ThreadID, frame_id: SessionData.FrameID, evaluate_name: []const u8, context: EvaluateContext) !void {
    const arguments = protocol.EvaluateArguments{
        .expression = evaluate_name,
        .frameId = @intFromEnum(frame_id),
        .line = null,
        .column = null,
        .source = null,
        .context = switch (context) {
            .watch => .watch,
            .repl => .repl,
            .hover => .hover,
            .clipboard => .clipboard,
            .variables => .variables,
        },
        .format = null,
    };

    _ = try connection.queue_request(
        .evaluate,
        arguments,
        .{ .evaluate = .{
            .thread_id = thread_id,
            .frame_id = frame_id,
            .expression = evaluate_name,
        } },
    );
}

pub fn step_in_targets(connection: *Connection, thread_id: SessionData.ThreadID, frame_id: SessionData.FrameID) !void {
    _ = try connection.queue_request(
        .stepInTargets,
        protocol.StepInTargetsArguments{
            .frameId = @intFromEnum(frame_id),
        },
        .{ .step_in_targets = .{
            .thread_id = thread_id,
            .frame_id = frame_id,
        } },
    );
}

pub fn goto_targets(connection: *Connection, source: protocol.Source, line: i32) !void {
    const source_id = SessionData.SourceID.from_source(source) orelse @panic("assert: Unidentifiable source");

    _ = try connection.queue_request(
        .gotoTargets,
        protocol.GotoTargetsArguments{
            .source = source,
            .line = line,
            .column = null,
        },
        .{ .goto_targets = .{
            .source_id = source_id,
            .line = line,
        } },
    );
}

pub fn loaded_sources(connection: *Connection) !void {
    try connection.queue_request(
        .loadedSources,
        // protocol.LoadedSourcesArguments{ .map = .{} },
        // FIXME: LoadedSourcesArguments should be an empty struct. Fix gen.zig
        .{}, // take no args.
        .no_data,
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
        fn stack_trace(_: *SessionData, _: *Connection) void {
            ui.state.active_source.scroll_to = .active_line;
            ui.state.update_active_source_to_top_of_stack = true;
        }

        fn step(_: *SessionData, _: *Connection) void {
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
    session.callback(callbacks, .success, .{ .response = .stackTrace }, static.stack_trace) catch return;
    const command: Connection.Command = switch (step_kind) {
        .next => .next,
        .in => .stepIn,
        .out => .stepOut,
    };
    session.callback(callbacks, .always, .{ .response = command }, static.step) catch return;
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

        _ = connection.queue_request(.stepIn, arg, .no_data) catch return;
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

        _ = connection.queue_request(.stepOut, arg, .no_data) catch return;
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

        _ = connection.queue_request(.next, arg, .no_data) catch return;
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

        _ = connection.queue_request(.@"continue", args, .no_data) catch return;
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
        }, .no_data) catch return;

        // TODO: Is this necessary ?
        // _ = connection.queue_request(
        //     .stackTrace,
        //     default_stack_trace_args(thread.id),
        //     .{ .dep = .{ .response = .threads }, .handled_when = .after_queueing },
        //     .{ .stack_trace = .{
        //         .thread_id = thread.id,
        //         .request_scopes = false,
        //         .request_variables = false,
        //     } },
        // ) catch return;
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
    }, .{ .set_breakpoints = .{ .source_id = source_id } });
}

pub fn set_data_breakpoints(data: *const SessionData, connection: *Connection) !void {
    try connection.queue_request(
        .setDataBreakpoints,
        protocol.SetDataBreakpointsArguments{ .breakpoints = data.data_breakpoints.keys() },

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
    }, .{
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
    }, .{
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
