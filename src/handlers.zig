const std = @import("std");
const protocol = @import("protocol.zig");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig").SessionData;
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");
const log = std.log.scoped(.handlers);

pub const Callbacks = std.ArrayList(Callback);
pub const Callback = struct {
    pub const Function = fn (data: *SessionData, connection: *Connection, message: ?Connection.RawMessage) void;
    pub const CallIf = enum {
        success,
        fail,
        always,
    };

    pub const WhenToCall = union(enum) {
        request_seq: i32,
        response: Connection.Command,
        any,
    };

    function: *const Function,
    message: ?Connection.RawMessage,
    call_if: CallIf,
    when_to_call: WhenToCall,
};

pub fn send_queued_requests(connection: *Connection) void {
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

pub fn handle_queued_responses(data: *SessionData, connection: *Connection) void {
    if (connection.expected_responses.items.len == 0) return;

    var i: usize = 0;
    while (i < connection.expected_responses.items.len) {
        const resp = connection.expected_responses.items[i];

        if (handle_response(data, connection, resp.command, resp.request_seq)) {
            _ = connection.expected_responses.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn handle_queued_events(callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    var i: usize = 0;
    while (i < connection.events.items.len) {
        const parsed = connection.events.items[i];
        const value = utils.get_value(parsed.value, "event", .string) orelse @panic("Only event should be here");
        const event = utils.string_to_enum(Connection.Event, value) orelse {
            log.err("Unknown event {s}", .{value});
            return;
        };
        const handled = handle_event(callbacks, data, connection, event) catch |err|
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

pub fn handle_event(callbacks: *Callbacks, data: *SessionData, connection: *Connection, event: Connection.Event) !bool {
    switch (event) {
        .stopped => {
            // Per the overview page: Request the threads on a stopped event
            const seq = try connection.queue_request(.threads, protocol.Object{}, .none);
            const parsed = try connection.get_and_parse_event(protocol.StoppedEvent, .stopped);
            defer parsed.deinit();
            const message = connection.remove_event(parsed.value.seq);

            try callback(callbacks, .success, .{ .request_seq = seq }, message, struct {
                pub fn function(d: *SessionData, c: *Connection, m: ?Connection.RawMessage) void {
                    defer m.?.deinit();
                    const e = std.json.parseFromValue(protocol.StoppedEvent, c.allocator, m.?.value, .{}) catch |err| {
                        log.err("Failed to handled event {}: {}", .{ @src(), err });
                        return;
                    };
                    defer e.deinit();
                    d.set_stopped(e.value) catch |err| {
                        log.err("Failed to handled event {}: {}", .{ @src(), err });
                    };

                    c.handled_event(.stopped, e.value.seq);
                }
            });

            return false;
        },
        .continued => {
            const parsed = try connection.get_and_parse_event(protocol.ContinuedEvent, .continued);
            defer parsed.deinit();

            data.set_continued(parsed.value);

            connection.handled_event(.continued, parsed.value.seq);
        },
        .exited => {
            const parsed = try connection.get_and_parse_event(protocol.ExitedEvent, .exited);
            defer parsed.deinit();

            try data.set_existed(parsed.value);

            connection.handled_event(.exited, parsed.value.seq);
        },
        .terminated => {
            const parsed = try connection.get_and_parse_event(protocol.TerminatedEvent, .terminated);
            defer parsed.deinit();

            try data.set_terminated(parsed.value);

            connection.handled_event(.terminated, parsed.value.seq);
        },
        .output => {
            const parsed = try connection.get_and_parse_event(protocol.OutputEvent, .output);
            defer parsed.deinit();

            try data.set_output(parsed.value);

            connection.handled_event(.output, parsed.value.seq);
        },
        .module => {
            const parsed = try connection.get_and_parse_event(protocol.ModuleEvent, .module);
            defer parsed.deinit();

            try data.set_modules(parsed.value);

            connection.handled_event(.module, parsed.value.seq);
        },
        .initialized => {
            const parsed = try connection.get_and_parse_event(protocol.InitializedEvent, .initialized);
            defer parsed.deinit();
            connection.handle_event_initialized(parsed.value.seq);
        },

        .thread => log.err("TODO event: {s}", .{@tagName(event)}),
        .breakpoint => log.err("TODO event: {s}", .{@tagName(event)}),
        .loadedSource => log.err("TODO event: {s}", .{@tagName(event)}),
        .process => log.err("TODO event: {s}", .{@tagName(event)}),
        .capabilities => log.err("TODO event: {s}", .{@tagName(event)}),
        .progressStart => log.err("TODO event: {s}", .{@tagName(event)}),
        .progressUpdate => log.err("TODO event: {s}", .{@tagName(event)}),
        .progressEnd => log.err("TODO event: {s}", .{@tagName(event)}),
        .invalidated => log.err("TODO event: {s}", .{@tagName(event)}),
        .memory => log.err("TODO event: {s}", .{@tagName(event)}),
    }

    return true;
}

pub fn handle_response(data: *SessionData, connection: *Connection, command: Connection.Command, request_seq: i32) bool {
    const err = switch (command) {
        .launch => blk: {
            acknowledge_only(connection, request_seq, command) catch |err| break :blk err;
            connection.handle_response_launch(request_seq);
        },
        .configurationDone,
        .pause,
        => acknowledge_and_handled(connection, request_seq, command),

        .initialize => connection.handle_response_init(request_seq),
        .disconnect => connection.handle_response_disconnect(request_seq),

        .threads => blk: {
            const parsed = connection.get_parse_validate_response(protocol.ThreadsResponse, request_seq, .threads) catch |err| break :blk err;
            defer parsed.deinit();

            data.set_threads(parsed.value.body.threads) catch |err| break :blk err;

            connection.handled_response(.threads, request_seq, true);
        },
        .stackTrace => blk: {
            const parsed = connection.get_parse_validate_response(protocol.StackTraceResponse, request_seq, .stackTrace) catch |err| break :blk err;
            defer parsed.deinit();

            data.set_stack_trace(parsed.value) catch |err| break :blk err;

            // TODO: request more stack traces if count > data.stack_frames.item.len
            const count = parsed.value.body.totalFrames orelse std.math.maxInt(i32);
            _ = count;

            connection.handled_response(.stackTrace, request_seq, true);
        },

        .cancel => log.err("TODO: {s}", .{@tagName(command)}),
        .runInTerminal => log.err("TODO: {s}", .{@tagName(command)}),
        .startDebugging => log.err("TODO: {s}", .{@tagName(command)}),
        .attach => log.err("TODO: {s}", .{@tagName(command)}),
        .restart => log.err("TODO: {s}", .{@tagName(command)}),
        .terminate => log.err("TODO: {s}", .{@tagName(command)}),
        .breakpointLocations => log.err("TODO: {s}", .{@tagName(command)}),
        .setBreakpoints => log.err("TODO: {s}", .{@tagName(command)}),
        .setFunctionBreakpoints => log.err("TODO: {s}", .{@tagName(command)}),
        .setExceptionBreakpoints => log.err("TODO: {s}", .{@tagName(command)}),
        .dataBreakpointInfo => log.err("TODO: {s}", .{@tagName(command)}),
        .setDataBreakpoints => log.err("TODO: {s}", .{@tagName(command)}),
        .setInstructionBreakpoints => log.err("TODO: {s}", .{@tagName(command)}),
        .@"continue" => log.err("TODO: {s}", .{@tagName(command)}),
        .next => log.err("TODO: {s}", .{@tagName(command)}),
        .stepIn => log.err("TODO: {s}", .{@tagName(command)}),
        .stepOut => log.err("TODO: {s}", .{@tagName(command)}),
        .stepBack => log.err("TODO: {s}", .{@tagName(command)}),
        .reverseContinue => log.err("TODO: {s}", .{@tagName(command)}),
        .restartFrame => log.err("TODO: {s}", .{@tagName(command)}),
        .goto => log.err("TODO: {s}", .{@tagName(command)}),
        .scopes => log.err("TODO: {s}", .{@tagName(command)}),
        .variables => log.err("TODO: {s}", .{@tagName(command)}),
        .setVariable => log.err("TODO: {s}", .{@tagName(command)}),
        .source => log.err("TODO: {s}", .{@tagName(command)}),
        .terminateThreads => log.err("TODO: {s}", .{@tagName(command)}),
        .modules => log.err("TODO: {s}", .{@tagName(command)}),
        .loadedSources => log.err("TODO: {s}", .{@tagName(command)}),
        .evaluate => log.err("TODO: {s}", .{@tagName(command)}),
        .setExpression => log.err("TODO: {s}", .{@tagName(command)}),
        .stepInTargets => log.err("TODO: {s}", .{@tagName(command)}),
        .gotoTargets => log.err("TODO: {s}", .{@tagName(command)}),
        .completions => log.err("TODO: {s}", .{@tagName(command)}),
        .exceptionInfo => log.err("TODO: {s}", .{@tagName(command)}),
        .readMemory => log.err("TODO: {s}", .{@tagName(command)}),
        .writeMemory => log.err("TODO: {s}", .{@tagName(command)}),
        .disassemble => log.err("TODO: {s}", .{@tagName(command)}),
        .locations => log.err("TODO: {s}", .{@tagName(command)}),
    };

    err catch |e| switch (e) {
        error.OutOfMemory,
        error.Overflow,
        error.InvalidCharacter,
        error.UnexpectedToken,
        error.InvalidNumber,
        error.InvalidEnumTag,
        error.DuplicateField,
        error.UnknownField,
        error.MissingField,
        error.LengthMismatch,
        error.InvalidSeqFromAdapter,
        error.WrongCommandForResponse,
        error.RequestResponseMismatchedRequestSeq,
        => {
            log.err("{!} from response of command {} request_seq {}", .{ e, command, request_seq });
            return false;
        },
        error.RequestFailed,
        error.ResponseDoesNotExist,
        => return false,
    };

    return true;
}

/// `container` is a container type with a function named `function`
pub fn callback(
    callbacks: *Callbacks,
    call_if: Callback.CallIf,
    when_to_call: Callback.WhenToCall,
    message: ?Connection.RawMessage,
    comptime container: anytype,
) !void {
    const func = comptime blk: {
        if (@TypeOf(@field(container, "function")) == Callback.Function) {
            break :blk @field(container, "function");
        } else {
            @compileError(
                "Callback function has the wrong type.\n" ++
                    "Expcted `" ++ @typeName(*const Callback.Function) ++ "`\n" ++
                    "Found `" ++ @typeName(@TypeOf(@field(container, "function"))),
            );
        }
    };

    const cb = Callback{
        .function = func,
        .message = message,
        .call_if = call_if,
        .when_to_call = when_to_call,
    };

    try callbacks.append(cb);
}

pub fn handle_callbacks(callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    for (connection.handled_responses.items) |resp| {
        var i: usize = 0;
        while (i < callbacks.items.len) {
            const cb = callbacks.items[i];
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
                _ = callbacks.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
}

fn acknowledge_and_handled(connection: *Connection, request_seq: i32, command: Connection.Command) !void {
    const resp = try connection.get_parse_validate_response(protocol.Response, request_seq, command);
    defer resp.deinit();
    connection.handled_response(command, request_seq, true);
}

fn acknowledge_only(connection: *Connection, request_seq: i32, command: Connection.Command) !void {
    const resp = try connection.get_parse_validate_response(protocol.Response, request_seq, command);
    resp.deinit();
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
