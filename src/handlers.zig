const std = @import("std");
const protocol = @import("protocol.zig");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");
const log = std.log.scoped(.handlers);
const request = @import("request.zig");

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
        const req = connection.queued_requests.items[i];
        if (dependency_satisfied(connection.*, req)) {
            defer _ = connection.queued_requests.orderedRemove(i);
            connection.send_request(req) catch |err| switch (err) {
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
    var i: usize = 0;
    while (i < connection.expected_responses.items.len) {
        const resp = connection.expected_responses.items[i];
        const err = handle_response(data, connection, resp);
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
            error.RequestFailed,
            => {
                log.err("{!} from response of command {} request_seq {}", .{ e, resp.command, resp.request_seq });
                i += 1;
                continue;
            },
            error.ResponseDoesNotExist => {
                i += 1;
                continue;
            },
        };

        _ = connection.expected_responses.orderedRemove(i);
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
    _ = callbacks;
    switch (event) {
        .stopped => {
            // Per the overview page: Request the threads on a stopped event
            _ = try connection.queue_request(.threads, protocol.Object{}, .none, .no_data);

            const parsed = try connection.get_and_parse_event(protocol.StoppedEvent, .stopped);
            defer parsed.deinit();

            try data.set_stopped(parsed.value);

            connection.handled_event(event, parsed.value.seq);
        },
        .continued => {
            const parsed = try connection.get_and_parse_event(protocol.ContinuedEvent, .continued);
            defer parsed.deinit();

            try data.set_continued(parsed.value);

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

pub fn handle_response(data: *SessionData, connection: *Connection, response: Connection.Response) !void {
    switch (response.command) {
        .launch => {
            try acknowledge_only(connection, response.request_seq, response.command);
            connection.handle_response_launch(response);
        },
        .configurationDone,
        .pause,
        => try acknowledge_and_handled(connection, response),

        .initialize => try connection.handle_response_init(response),
        .disconnect => try connection.handle_response_disconnect(response),

        .threads => {
            const parsed = try connection.get_parse_validate_response(protocol.ThreadsResponse, response.request_seq, .threads);
            defer parsed.deinit();

            try data.set_threads(parsed.value.body.threads);

            connection.handled_response(response, .success);
        },
        .stackTrace => {
            const parsed = try connection.get_parse_validate_response(protocol.StackTraceResponse, response.request_seq, .stackTrace);
            defer parsed.deinit();
            const retained = response.request_data.stack_trace;

            if (parsed.value.body.stackFrames.len == 0) {
                return;
            }

            try data.set_stack_frames(retained.thread_id, parsed.value);

            // codelldb doesn't include totalFrames even when it should.
            // orelse 0 to avoid infinitely requesting stack traces
            const count = parsed.value.body.totalFrames orelse 0;
            defer connection.handled_response(response, .success);
            if (count > data.stack_frames.items.len) {
                _ = try connection.queue_request(
                    .stackTrace,
                    protocol.StackTraceArguments{ .threadId = retained.thread_id },
                    .none,
                    .{ .stack_trace = retained },
                );
            } else if (retained.request_scopes) {
                for (data.stack_frames.items) |frame| {
                    _ = try connection.queue_request(
                        .scopes,
                        protocol.ScopesArguments{ .frameId = frame.data.id },
                        .none,
                        .{ .scopes = .{ .frame_id = frame.data.id } },
                    );
                }
            }
        },
        .scopes => {
            const parsed = try connection.get_parse_validate_response(protocol.ScopesResponse, response.request_seq, response.command);
            defer parsed.deinit();

            try data.set_scopes(response.request_data.scopes.frame_id, parsed.value.body.scopes);

            connection.handled_response(response, .success);
        },

        .cancel => log.err("TODO: {s}", .{@tagName(response.command)}),
        .runInTerminal => log.err("TODO: {s}", .{@tagName(response.command)}),
        .startDebugging => log.err("TODO: {s}", .{@tagName(response.command)}),
        .attach => log.err("TODO: {s}", .{@tagName(response.command)}),
        .restart => log.err("TODO: {s}", .{@tagName(response.command)}),
        .terminate => log.err("TODO: {s}", .{@tagName(response.command)}),
        .breakpointLocations => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setBreakpoints => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setFunctionBreakpoints => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setExceptionBreakpoints => log.err("TODO: {s}", .{@tagName(response.command)}),
        .dataBreakpointInfo => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setDataBreakpoints => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setInstructionBreakpoints => log.err("TODO: {s}", .{@tagName(response.command)}),
        .@"continue" => log.err("TODO: {s}", .{@tagName(response.command)}),
        .next => log.err("TODO: {s}", .{@tagName(response.command)}),
        .stepIn => log.err("TODO: {s}", .{@tagName(response.command)}),
        .stepOut => log.err("TODO: {s}", .{@tagName(response.command)}),
        .stepBack => log.err("TODO: {s}", .{@tagName(response.command)}),
        .reverseContinue => log.err("TODO: {s}", .{@tagName(response.command)}),
        .restartFrame => log.err("TODO: {s}", .{@tagName(response.command)}),
        .goto => log.err("TODO: {s}", .{@tagName(response.command)}),
        .variables => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setVariable => log.err("TODO: {s}", .{@tagName(response.command)}),
        .source => log.err("TODO: {s}", .{@tagName(response.command)}),
        .terminateThreads => log.err("TODO: {s}", .{@tagName(response.command)}),
        .modules => log.err("TODO: {s}", .{@tagName(response.command)}),
        .loadedSources => log.err("TODO: {s}", .{@tagName(response.command)}),
        .evaluate => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setExpression => log.err("TODO: {s}", .{@tagName(response.command)}),
        .stepInTargets => log.err("TODO: {s}", .{@tagName(response.command)}),
        .gotoTargets => log.err("TODO: {s}", .{@tagName(response.command)}),
        .completions => log.err("TODO: {s}", .{@tagName(response.command)}),
        .exceptionInfo => log.err("TODO: {s}", .{@tagName(response.command)}),
        .readMemory => log.err("TODO: {s}", .{@tagName(response.command)}),
        .writeMemory => log.err("TODO: {s}", .{@tagName(response.command)}),
        .disassemble => log.err("TODO: {s}", .{@tagName(response.command)}),
        .locations => log.err("TODO: {s}", .{@tagName(response.command)}),
    }
}

/// `container` is a container type with a function named `function`
pub fn callback(
    callbacks: *Callbacks,
    call_if: Callback.CallIf,
    when_to_call: Callback.WhenToCall,
    message: ?Connection.RawMessage,
    comptime function: Callback.Function,
) !void {
    const cb = Callback{
        .function = function,
        .message = message,
        .call_if = call_if,
        .when_to_call = when_to_call,
    };

    try callbacks.append(cb);
}

pub fn handle_callbacks(callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    for (connection.handled_responses.items) |handled| {
        var i: usize = 0;
        while (i < callbacks.items.len) {
            const cb = callbacks.items[i];
            const call_if = switch (cb.call_if) {
                .success => handled.status == .success,
                .fail => handled.status == .failure,
                .always => true,
            };

            const when_to_call = switch (cb.when_to_call) {
                .request_seq => |wanted| wanted == handled.response.request_seq,
                .response => |wanted| wanted == handled.response.command,
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

fn acknowledge_and_handled(connection: *Connection, response: Connection.Response) !void {
    const resp = try connection.get_parse_validate_response(protocol.Response, response.request_seq, response.command);
    defer resp.deinit();
    connection.handled_response(response, .success);
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
                if (item.response.request_seq == seq) return true;
            }
        },
        .response => |command| {
            for (connection.handled_responses.items) |item| {
                if (item.response.command == command) return true;
            }
        },
        .none => return true,
    }

    return false;
}
