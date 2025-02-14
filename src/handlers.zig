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
        connection.send_request(i) catch |err| switch (err) {
            error.DependencyNotSatisfied => {
                i += 1;
            },

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
                i += 1;
                log.err("{}\n", .{err});
            },
        };
    }
}

pub fn handle_queued_messages(callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    while (connection.messages.removeOrNull()) |message| {
        var ok = false;
        const message_type = utils.get_value(message.value, "type", .string).?;
        if (std.mem.eql(u8, message_type, "event")) {
            ok = handle_event_message(message, callbacks, data, connection);
        } else if (std.mem.eql(u8, message_type, "response")) {
            const request_seq: i32 = @truncate(utils.get_value(message.value, "request_seq", .integer).?);
            ok = handle_response_message(message, request_seq, data, connection);
        } else {
            @panic("opps!");
        }

        if (!ok) {
            connection.failed_message(message);
        }
    }
}

pub fn handle_response_message(message: Connection.RawMessage, request_seq: i32, data: *SessionData, connection: *Connection) bool {
    const resp, const index = connection.get_response_by_request_seq(request_seq).?;
    const err = handle_response(message, data, connection, resp);

    err catch |e| switch (e) {
        error.NoBreakpointIDGiven,
        error.BreakpointDoesNotExist,
        error.InvalidBreakpointResponse,

        error.OutOfMemory,
        error.Overflow,
        error.InvalidCharacter,
        error.UnexpectedToken,
        error.InvalidNumber,
        error.InvalidEnumTag,
        error.DuplicateField,
        error.LengthMismatch,
        error.WrongCommandForResponse,
        => {
            log.err("{!} from response of command {} request_seq {}", .{ e, resp.command, resp.request_seq });
            return false;
        },

        error.UnknownField,
        error.MissingField,
        error.RequestResponseMismatchedRequestSeq,
        error.RequestFailed,
        => {
            log.err("{!} from response of command {} request_seq {}", .{ e, resp.command, resp.request_seq });
            return false;
        },
    };

    _ = connection.expected_responses.orderedRemove(index);
    return true;
}

pub fn handle_event_message(message: Connection.RawMessage, callbacks: *Callbacks, data: *SessionData, connection: *Connection) bool {
    const value = utils.get_value(message.value, "event", .string) orelse @panic("Only event should be here");
    const event = utils.string_to_enum(Connection.Event, value) orelse {
        log.err("Unknown event {s}", .{value});
        return false;
    };
    handle_event(message, callbacks, data, connection, event) catch |err| switch (err) {
        else => {
            log.err("{}", .{err});
            return false;
        },
    };

    return true;
}

pub fn handle_event(message: Connection.RawMessage, callbacks: *Callbacks, data: *SessionData, connection: *Connection, event: Connection.Event) !void {
    _ = callbacks;
    switch (event) {
        .stopped => {
            // Per the overview page: Request the threads on a stopped event
            _ = try connection.queue_request(.threads, protocol.Object{}, .none, .no_data);

            const parsed = try connection.parse_event(message, protocol.StoppedEvent, .stopped);
            defer parsed.deinit();

            try data.set_stopped(parsed.value);

            connection.handled_event(message, event);
        },
        .continued => {
            const parsed = try connection.parse_event(message, protocol.ContinuedEvent, .continued);
            defer parsed.deinit();

            try data.set_continued(parsed.value);

            connection.handled_event(message, .continued);
        },
        .exited => {
            const parsed = try connection.parse_event(message, protocol.ExitedEvent, .exited);
            defer parsed.deinit();

            try data.set_existed(parsed.value);

            connection.handled_event(message, .exited);
        },
        .terminated => {
            const parsed = try connection.parse_event(message, protocol.TerminatedEvent, .terminated);
            defer parsed.deinit();

            try data.set_terminated(parsed.value);

            connection.handled_event(message, .terminated);
        },
        .output => {
            const parsed = try connection.parse_event(message, protocol.OutputEvent, .output);
            defer parsed.deinit();

            try data.set_output(parsed.value);

            connection.handled_event(message, .output);
        },
        .module => {
            const parsed = try connection.parse_event(message, protocol.ModuleEvent, .module);
            defer parsed.deinit();

            try data.set_modules(parsed.value);

            connection.handled_event(message, .module);
        },
        .initialized => {
            const parsed = try connection.parse_event(message, protocol.InitializedEvent, .initialized);
            defer parsed.deinit();
            connection.handle_event_initialized(message);
        },
        .breakpoint => {
            const parsed = try connection.parse_event(message, protocol.BreakpointEvent, .breakpoint);
            defer parsed.deinit();

            const body = parsed.value.body;
            switch (body.reason) {
                .changed, .new => try data.set_breakpoints(.event, &.{body.breakpoint}),
                .removed => data.remove_breakpoint(body.breakpoint.id),
                .string => |string| log.err(
                    "TODO event: {s} in switch case {s}",
                    .{ @tagName(event), string },
                ),
            }

            connection.handled_event(message, .breakpoint);
        },

        .thread => log.err("TODO event: {s}", .{@tagName(event)}),
        .loadedSource => log.err("TODO event: {s}", .{@tagName(event)}),
        .process => log.err("TODO event: {s}", .{@tagName(event)}),
        .capabilities => log.err("TODO event: {s}", .{@tagName(event)}),
        .progressStart => log.err("TODO event: {s}", .{@tagName(event)}),
        .progressUpdate => log.err("TODO event: {s}", .{@tagName(event)}),
        .progressEnd => log.err("TODO event: {s}", .{@tagName(event)}),
        .invalidated => log.err("TODO event: {s}", .{@tagName(event)}),
        .memory => log.err("TODO event: {s}", .{@tagName(event)}),
    }
}

pub fn handle_response(message: Connection.RawMessage, data: *SessionData, connection: *Connection, response: Connection.Response) !void {
    switch (response.command) {
        .launch => {
            try acknowledge_only(message, connection, response.request_seq, response.command);
            connection.handle_response_launch(message, response);
        },

        .configurationDone,
        .pause,
        => try acknowledge_and_handled(message, connection, response),

        .next => {
            const retained = response.request_data.next;
            if (retained.request_stack_trace) {
                _ = try connection.queue_request(
                    .stackTrace,
                    protocol.StackTraceArguments{ .threadId = retained.thread_id },
                    .none,
                    .{ .stack_trace = .{
                        .thread_id = retained.thread_id,
                        .request_scopes = retained.request_scopes,
                        .request_variables = retained.request_variables,
                    } },
                );
            }

            try acknowledge_and_handled(message, connection, response);
        },

        .initialize => try connection.handle_response_init(message, response),
        .disconnect => try connection.handle_response_disconnect(message, response),

        .threads => {
            const parsed = try connection.parse_validate_response(message, protocol.ThreadsResponse, response.request_seq, .threads);
            defer parsed.deinit();

            try data.set_threads(parsed.value.body.threads);

            connection.handled_response(message, response, .success);
        },
        .stackTrace => {
            const parsed = try connection.parse_validate_response(message, protocol.StackTraceResponse, response.request_seq, .stackTrace);
            defer parsed.deinit();
            const retained = response.request_data.stack_trace;

            if (parsed.value.body.stackFrames.len == 0) {
                return;
            }

            const total: usize = @intCast(parsed.value.body.totalFrames orelse 0);
            const request_more = total > parsed.value.body.stackFrames.len;

            try data.set_stack(retained.thread_id, !request_more, parsed.value.body.stackFrames);

            const thread = data.threads.get(retained.thread_id) orelse return;
            // codelldb doesn't include totalFrames even when it should.
            // orelse 0 to avoid infinitely requesting stack traces
            defer connection.handled_response(message, response, .success);
            if (request_more) {
                _ = try connection.queue_request(
                    .stackTrace,
                    protocol.StackTraceArguments{ .threadId = retained.thread_id },
                    .none,
                    .{ .stack_trace = retained },
                );
            } else if (retained.request_scopes) {
                for (thread.stack.items) |frame| {
                    _ = try connection.queue_request(
                        .scopes,
                        protocol.ScopesArguments{ .frameId = frame.id },
                        .none,
                        .{
                            .scopes = .{
                                .frame_id = frame.id,
                                .request_variables = retained.request_variables,
                            },
                        },
                    );
                }
            }
        },
        .scopes => {
            const parsed = try connection.parse_validate_response(message, protocol.ScopesResponse, response.request_seq, response.command);
            defer parsed.deinit();
            const retained = response.request_data.scopes;

            try data.set_scopes(retained.frame_id, parsed.value.body.scopes);
            defer connection.handled_response(message, response, .success);

            if (retained.request_variables) {
                for (parsed.value.body.scopes) |scope| {
                    _ = try connection.queue_request(
                        .variables,
                        protocol.VariablesArguments{ .variablesReference = scope.variablesReference },
                        .none,
                        .{ .variables = .{ .variables_reference = scope.variablesReference } },
                    );
                }
            }
        },
        .variables => {
            const parsed = try connection.parse_validate_response(
                message,
                protocol.VariablesResponse,
                response.request_seq,
                .variables,
            );
            defer parsed.deinit();
            const retained = response.request_data.variables;
            try data.set_variables(retained.variables_reference, parsed.value.body.variables);

            connection.handled_response(message, response, .success);
        },

        .setFunctionBreakpoints => {
            const parsed = try connection.parse_validate_response(
                message,
                protocol.SetFunctionBreakpointsResponse,
                response.request_seq,
                response.command,
            );
            defer parsed.deinit();

            try data.set_breakpoints(.function, parsed.value.body.breakpoints);

            connection.handled_response(message, response, .success);
        },
        .setBreakpoints => {
            const parsed = try connection.parse_validate_response(
                message,
                protocol.SetBreakpointsResponse,
                response.request_seq,
                response.command,
            );
            defer parsed.deinit();

            const retained = response.request_data.set_breakpoints;

            try data.set_breakpoints(.{
                .source = retained.source_id,
            }, parsed.value.body.breakpoints);

            connection.handled_response(message, response, .success);
        },
        .source => {
            const parsed = try connection.parse_validate_response(
                message,
                protocol.SourceResponse,
                response.request_seq,
                response.command,
            );
            defer parsed.deinit();
            const retained = response.request_data.source;

            try data.set_source_content(.{ .reference = retained.source_reference }, .{
                .content = parsed.value.body.content,
                .mime_type = parsed.value.body.mimeType,
            });

            connection.handled_response(message, response, .success);
        },
        .@"continue" => {
            const parsed = try connection.parse_validate_response(
                message,
                protocol.ContinueResponse,
                response.request_seq,
                response.command,
            );
            defer parsed.deinit();

            if (parsed.value.body.allThreadsContinued orelse true) {
                data.set_continued_all();
            }

            connection.handled_response(message, response, .success);
        },

        .cancel => log.err("TODO: {s}", .{@tagName(response.command)}),
        .runInTerminal => log.err("TODO: {s}", .{@tagName(response.command)}),
        .startDebugging => log.err("TODO: {s}", .{@tagName(response.command)}),
        .attach => log.err("TODO: {s}", .{@tagName(response.command)}),
        .restart => log.err("TODO: {s}", .{@tagName(response.command)}),
        .terminate => log.err("TODO: {s}", .{@tagName(response.command)}),
        .breakpointLocations => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setExceptionBreakpoints => log.err("TODO: {s}", .{@tagName(response.command)}),
        .dataBreakpointInfo => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setDataBreakpoints => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setInstructionBreakpoints => log.err("TODO: {s}", .{@tagName(response.command)}),
        .stepIn => log.err("TODO: {s}", .{@tagName(response.command)}),
        .stepOut => log.err("TODO: {s}", .{@tagName(response.command)}),
        .stepBack => log.err("TODO: {s}", .{@tagName(response.command)}),
        .reverseContinue => log.err("TODO: {s}", .{@tagName(response.command)}),
        .restartFrame => log.err("TODO: {s}", .{@tagName(response.command)}),
        .goto => log.err("TODO: {s}", .{@tagName(response.command)}),
        .setVariable => log.err("TODO: {s}", .{@tagName(response.command)}),
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

fn acknowledge_and_handled(message: Connection.RawMessage, connection: *Connection, response: Connection.Response) !void {
    const resp = try connection.parse_validate_response(message, protocol.Response, response.request_seq, response.command);
    defer resp.deinit();
    connection.handled_response(message, response, .success);
}

fn acknowledge_only(message: Connection.RawMessage, connection: *Connection, request_seq: i32, command: Connection.Command) !void {
    const resp = try connection.parse_validate_response(message, protocol.Response, request_seq, command);
    resp.deinit();
}
