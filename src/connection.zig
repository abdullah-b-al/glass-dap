const std = @import("std");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const SessionData = @import("session_data.zig");
const io = @import("io.zig");
const fs = std.fs;

const log = std.log.scoped(.connection);

const Connection = @This();

allocator: std.mem.Allocator,
/// Used for deeply cloned values
arena: std.heap.ArenaAllocator,
adapter: Adapter,

client_capabilities: ClientCapabilitiesSet,
adapter_capabilities: AdapterCapabilities,

queued_requests: std.ArrayList(Request),
expected_responses: std.ArrayList(Response),
handled_responses: std.ArrayList(HandledResponse),
handled_events: std.ArrayList(HandledEvent),

total_requests: u32 = 0,

total_responses_received: u32 = 0,
total_events_received: u32 = 0,
total_messages_received: u32 = 0,
messages: Messages,

debug_requests: std.ArrayList(Request),
debug_failed_messages: std.ArrayList(RawMessage),
debug_handled_responses: std.ArrayList(RawMessage),
debug_handled_events: std.ArrayList(RawMessage),
debug_messages_with_unknown_fields: std.ArrayList(RawMessage),

/// When true this flag will prevent freeing of messages
debug: bool,

/// Used for the seq field in the protocol. Starts at 1
seq: u32,
pub fn init(allocator: std.mem.Allocator, debug: bool) Connection {
    return .{
        .seq = 1,
        .adapter = Adapter.init(allocator),
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .queued_requests = std.ArrayList(Request).init(allocator),
        .debug_requests = std.ArrayList(Request).init(allocator),
        .messages = Messages.init(allocator, {}),
        .expected_responses = std.ArrayList(Response).init(allocator),
        .handled_responses = std.ArrayList(HandledResponse).init(allocator),
        .handled_events = std.ArrayList(HandledEvent).init(allocator),

        .debug_failed_messages = std.ArrayList(RawMessage).init(allocator),
        .debug_handled_responses = std.ArrayList(RawMessage).init(allocator),
        .debug_handled_events = std.ArrayList(RawMessage).init(allocator),
        .debug_messages_with_unknown_fields = std.ArrayList(RawMessage).init(allocator),
        .debug = debug,
        .client_capabilities = .{},
        .adapter_capabilities = .{},
        .total_requests = 0,
        .total_events_received = 0,
        .total_messages_received = 0,
        .total_responses_received = 0,
    };
}

fn free(connection: *Connection, reason: enum { deinit, begin_session }) void {
    const to_free_with_items = .{
        &connection.queued_requests,
        &connection.messages,
    };

    const to_free = .{
        &connection.expected_responses,
        &connection.handled_responses,
        &connection.handled_events,
    };

    inline for (to_free_with_items) |ptr| {
        for (ptr.items) |*item| item.deinit();

        switch (reason) {
            .deinit => ptr.deinit(),
            .begin_session => ptr.clearAndFree(),
        }
    }

    inline for (to_free) |ptr| {
        switch (reason) {
            .deinit => ptr.deinit(),
            .begin_session => ptr.clearAndFree(),
        }
    }

    switch (reason) {
        .deinit => connection.free_debug(.deinit),
        .begin_session => connection.free_debug(.begin_session),
    }

    switch (reason) {
        .deinit => {
            connection.adapter.deinit();
            connection.arena.deinit();
        },
        // the adapter should only be freed at the end of the program
        // as it contains data required at different points
        .begin_session => _ = connection.arena.reset(.free_all),
    }

    connection.* = Connection{
        .seq = 1,
        .allocator = connection.allocator,
        .arena = connection.arena,
        .adapter = connection.adapter,
        .client_capabilities = connection.client_capabilities,
        .adapter_capabilities = .{},

        .queued_requests = connection.queued_requests,
        .debug_requests = connection.debug_requests,
        .messages = connection.messages,
        .expected_responses = connection.expected_responses,
        .handled_responses = connection.handled_responses,
        .handled_events = connection.handled_events,

        .debug_failed_messages = connection.debug_failed_messages,
        .debug_handled_responses = connection.debug_handled_responses,
        .debug_handled_events = connection.debug_handled_events,
        .debug_messages_with_unknown_fields = connection.debug_messages_with_unknown_fields,
        .debug = connection.debug,
        .total_requests = 0,
        .total_events_received = 0,
        .total_messages_received = 0,
        .total_responses_received = 0,
    };
}

fn free_debug(connection: *Connection, reason: enum { deinit, begin_session }) void {
    const debug_to_free = .{
        &connection.debug_requests,
        &connection.debug_failed_messages,
        &connection.debug_handled_responses,
        &connection.debug_handled_events,

        // Do not free it's elements
        // Contains copies to messages in the other debug_ fields
        // connection.debug_messages_with_unknown_fields,
    };

    switch (reason) {
        .begin_session => {
            inline for (debug_to_free) |ptr| {
                for (ptr.items) |*item| item.deinit();
                ptr.clearAndFree();
            }
        },
        .deinit => {
            inline for (debug_to_free) |ptr| {
                for (ptr.items) |*item| item.deinit();
                ptr.deinit();
            }
        },
    }

    switch (reason) {
        .begin_session => connection.debug_messages_with_unknown_fields.clearAndFree(),
        .deinit => connection.debug_messages_with_unknown_fields.deinit(),
    }
}

pub fn deinit(connection: *Connection) void {
    connection.free(.deinit);
}

pub fn begin_session(connection: *Connection) void {
    std.debug.assert(connection.adapter.state == .spawned or connection.adapter.state == .initialized);
    connection.free(.begin_session);
}

pub fn queue_request(connection: *Connection, comptime command: Command, arguments: anytype, request_data: RetainedRequestData) !void {
    switch (connection.adapter.state) {
        .partially_initialized => {
            switch (command) {
                .launch, .attach => {},
                else => return error.AdapterNotDoneInitializing,
            }
        },
        .initializing => {
            switch (command) {
                .initialize, .launch, .attach, .configurationDone => {},
                else => return error.AdapterNotDoneInitializing,
            }
        },
        .died, .not_spawned => return error.AdapterNotSpawned,
        .initialized, .spawned, .attached, .launched => {},
    }

    const total_requests = connection.total_requests + 1;
    try connection.queued_requests.ensureUnusedCapacity(1);
    try connection.debug_requests.ensureTotalCapacity(total_requests);

    // don't use the request's arena so as not to free the expected_responses data
    // when the request is sent
    const cloned_request_data = blk: {
        const cloner = connection.create_cloner();
        break :blk try utils.clone_anytype(cloner, request_data);
    };

    // FIXME: This leaks for some reason.
    var arena = std.heap.ArenaAllocator.init(connection.allocator);
    errdefer arena.deinit();

    const cloner = .{ .allocator = arena.allocator() };

    const object = switch (@TypeOf(arguments)) {
        @TypeOf(null) => protocol.Object{},
        protocol.Object => arguments,
        else => try utils.value_to_object(arena.allocator(), arguments),
    };

    const args = try utils.clone_anytype(cloner, object);

    connection.queued_requests.appendAssumeCapacity(.{
        .arena = arena,
        .args = args,
        .command = command,
        .request_data = cloned_request_data,
    });
    connection.total_requests = total_requests;
}

pub fn send_request(connection: *Connection, index: usize) !void {
    var request = &connection.queued_requests.items[index];
    try connection.expected_responses.ensureUnusedCapacity(1);

    switch (connection.adapter.state) {
        .partially_initialized => {
            switch (request.command) {
                .launch, .attach => {},
                else => return error.AdapterNotDoneInitializing,
            }
        },
        .initializing => {
            switch (request.command) {
                .initialize => {},
                else => return error.AdapterNotDoneInitializing,
            }
        },
        .died, .not_spawned => return error.AdapterNotSpawned,
        .initialized, .spawned, .attached, .launched => {},
    }

    const protocol_request = protocol.Request{
        .seq = connection.new_seq(),
        .type = .request,
        .command = @tagName(request.command),
        .arguments = .{ .object = request.args },
    };

    const as_object = try utils.value_to_object(request.arena.allocator(), protocol_request);

    try connection.check_request_capability(request.command);
    const message = try io.create_message(connection.allocator, as_object);
    defer connection.allocator.free(message);
    try connection.adapter.write_all(message);

    connection.expected_responses.appendAssumeCapacity(.{
        .request_seq = protocol_request.seq,
        .command = request.command,
        .request_data = request.request_data,
    });

    _ = connection.remove_request(index, protocol_request.seq);
}

pub fn remove_request(connection: *Connection, index: usize, debug_request_seq: ?i32) Command {
    var request = &connection.queued_requests.items[index];
    const command = request.command;

    if (connection.debug) {
        request.debug_request_seq = debug_request_seq;
        connection.debug_requests.appendAssumeCapacity(request.*);
    } else {
        request.arena.deinit();
    }

    _ = connection.queued_requests.orderedRemove(index);

    return command;
}

pub fn remove_event(connection: *Connection, seq: i32) RawMessage {
    _, const index = connection.get_event(seq) catch @panic("Only call this if you got an event");
    return connection.events.orderedRemove(index);
}

pub fn handled_event(connection: *Connection, message: RawMessage, event: Event) void {
    connection.handled_events.appendAssumeCapacity(.{
        .event = event,
        .timestamp = std.time.nanoTimestamp(),
    });
    if (connection.debug) {
        connection.debug_handled_events.appendAssumeCapacity(message);
    } else {
        message.deinit();
    }
}

pub fn handled_response(connection: *Connection, message: RawMessage, response: Response, status: ResponseStatus) void {
    connection.handled_responses.appendAssumeCapacity(.{
        .response = response,
        .status = status,
        .timestamp = std.time.nanoTimestamp(),
    });
    if (connection.debug) {
        connection.debug_handled_responses.appendAssumeCapacity(message);
    } else {
        message.deinit();
    }
}

pub fn failed_message(connection: *Connection, message: RawMessage) void {
    if (connection.debug) {
        connection.debug_failed_messages.appendAssumeCapacity(message);
    } else {
        message.deinit();
    }
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn queue_request_init(connection: *Connection, arguments: protocol.InitializeRequestArguments) !void {
    connection.client_capabilities = utils.bit_set_from_struct(arguments, ClientCapabilitiesSet, ClientCapabilitiesKind);

    try connection.queue_request(.initialize, arguments, .no_data);
    connection.adapter.state = .initializing;
}

pub fn handle_response_init(connection: *Connection, message: RawMessage, response: Response) !void {
    std.debug.assert(connection.adapter.state == .initializing);
    const cloner = connection.create_cloner();

    const resp = try connection.parse_validate_response(message, protocol.InitializeResponse, response.request_seq, .initialize);
    defer resp.deinit();
    if (resp.value.body) |body| {
        connection.adapter_capabilities.support = utils.bit_set_from_struct(body, AdapterCapabilitiesSet, AdapterCapabilitiesKind);
        connection.adapter_capabilities.completionTriggerCharacters = try utils.clone_anytype(cloner, body.completionTriggerCharacters);
        connection.adapter_capabilities.exceptionBreakpointFilters = try utils.clone_anytype(cloner, body.exceptionBreakpointFilters);
        connection.adapter_capabilities.additionalModuleColumns = try utils.clone_anytype(cloner, body.additionalModuleColumns);
        connection.adapter_capabilities.supportedChecksumAlgorithms = try utils.clone_anytype(cloner, body.supportedChecksumAlgorithms);
        connection.adapter_capabilities.breakpointModes = try utils.clone_anytype(cloner, body.breakpointModes);
    }

    connection.adapter.state = .partially_initialized;
    connection.handled_response(message, response, .success);
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn queue_request_launch(connection: *Connection, arguments: protocol.LaunchRequestArguments, extra_arguments: protocol.Object) !void {
    var args = try utils.value_to_object(connection.arena.allocator(), arguments);
    try utils.object_merge(connection.arena.allocator(), &args, extra_arguments);
    try connection.queue_request(.launch, args, .no_data);
}

pub fn handle_response_launch(connection: *Connection, message: RawMessage, response: Response) void {
    connection.adapter.state = .launched;
    connection.handled_response(message, response, .success);
}

pub fn queue_request_configuration_done(connection: *Connection, arguments: ?protocol.ConfigurationDoneArguments, extra_arguments: protocol.Object) !void {
    var args = try utils.value_to_object(connection.arena.allocator(), arguments);
    try utils.object_merge(connection.arena.allocator(), &args, extra_arguments);
    try connection.queue_request(.configurationDone, args, .no_data);
}

pub fn handle_response_disconnect(connection: *Connection, message: RawMessage, response: Response) !void {
    const resp = try connection.parse_validate_response(
        message,
        protocol.DisconnectResponse,
        response.request_seq,
        response.command,
    );
    defer resp.deinit();
    try validate_response(resp.value, response.request_seq, .disconnect);

    if (resp.value.success) {
        connection.adapter.state = .initialized;
    }

    connection.handled_response(message, response, .success);
}

pub fn handle_event_initialized(connection: *Connection, message: RawMessage) void {
    connection.adapter.state = .initialized;
    connection.handled_event(message, .initialized);
}

pub fn handle_event_terminated(connection: *Connection, message: RawMessage) void {
    connection.adapter.state = .initialized;
    connection.handled_event(message, .terminated);
}

pub fn check_request_capability(connection: *Connection, command: Command) !void {
    const s = connection.adapter_capabilities.support;
    const c = connection.adapter_capabilities;
    const result = switch (command) {
        .dataBreakpointInfo, .setDataBreakpoints => s.contains(.supportsDataBreakpoints),
        .stepBack, .reverseContinue => s.contains(.supportsStepBack),

        .configurationDone => s.contains(.supportsConfigurationDoneRequest),
        .setFunctionBreakpoints => s.contains(.supportsFunctionBreakpoints),
        .setVariable => s.contains(.supportsSetVariable),
        .restartFrame => s.contains(.supportsRestartFrame),
        .gotoTargets => s.contains(.supportsGotoTargetsRequest),
        .stepInTargets => s.contains(.supportsStepInTargetsRequest),
        .completions => s.contains(.supportsCompletionsRequest),
        .modules => s.contains(.supportsModulesRequest),
        .restart => s.contains(.supportsRestartRequest),
        .exceptionInfo => s.contains(.supportsExceptionInfoRequest),
        .loadedSources => s.contains(.supportsLoadedSourcesRequest),
        .terminateThreads => s.contains(.supportsTerminateThreadsRequest),
        .setExpression => s.contains(.supportsSetExpression),
        .terminate => s.contains(.supportsTerminateRequest),
        .cancel => s.contains(.supportsCancelRequest),
        .breakpointLocations => s.contains(.supportsBreakpointLocationsRequest),
        .setInstructionBreakpoints => s.contains(.supportsInstructionBreakpoints),
        .readMemory => s.contains(.supportsReadMemoryRequest),
        .writeMemory => s.contains(.supportsWriteMemoryRequest),
        .disassemble => s.contains(.supportsDisassembleRequest),
        .goto => s.contains(.supportsGotoTargetsRequest),

        .setExceptionBreakpoints => (c.exceptionBreakpointFilters orelse &.{}).len > 1,

        .locations,
        .evaluate,
        .source,
        .threads,
        .variables,
        .scopes,
        .@"continue",
        .pause,
        .stackTrace,
        .stepIn,
        .stepOut,
        .setBreakpoints,
        .next,
        .disconnect,
        .launch,
        .attach,
        .initialize,
        => true,

        .startDebugging, .runInTerminal => @panic("This is a reverse request"),
    };

    if (!result) {
        return error.AdapterDoesNotSupportRequest;
    }
}

pub fn adapter_died(connection: *Connection) void {
    connection.adapter.state = .died;
}

pub fn new_seq(s: *Connection) i32 {
    const seq = s.seq;
    s.seq += 1;
    return @intCast(seq);
}

pub fn peek_seq(s: Connection) i32 {
    return @intCast(s.seq + 1);
}

pub fn queue_messages(connection: *Connection, timeout_ms: u64) !bool {
    const adapter = connection.adapter.process orelse return false;
    const stdout = adapter.stdout orelse return false;
    if (try io.message_exists(stdout, connection.allocator, timeout_ms)) {
        try connection.messages.ensureTotalCapacity(connection.total_messages_received + 1);
        try connection.debug_failed_messages.ensureTotalCapacity(connection.messages.cap);
        try connection.debug_messages_with_unknown_fields.ensureTotalCapacity(connection.total_messages_received + 1);

        const responses_capacity = connection.total_responses_received + 1;
        try connection.handled_responses.ensureTotalCapacity(responses_capacity);
        try connection.debug_handled_responses.ensureTotalCapacity(responses_capacity);

        const events_capacity = connection.total_events_received + 1;
        try connection.handled_events.ensureTotalCapacity(events_capacity);
        try connection.debug_handled_events.ensureTotalCapacity(events_capacity);

        const parsed = try io.read_message(stdout, connection.allocator);
        errdefer {
            std.log.err("{}\n", .{parsed});
            parsed.deinit();
        }
        const message_type = utils.get_value(parsed.value, "type", .string) orelse return error.InvalidMessage;

        if (std.mem.eql(u8, message_type, "response")) {
            if (utils.get_value(parsed.value, "request_seq", .integer) == null) {
                return error.InvalidMessage;
            }

            connection.total_responses_received += 1;
        } else if (std.mem.eql(u8, message_type, "event")) {
            connection.total_events_received += 1;
        } else {
            return error.UnknownMessage;
        }

        connection.total_messages_received += 1;
        connection.messages.add(parsed) catch |err| switch (err) {
            error.OutOfMemory => unreachable,
        };

        return true;
    }

    return false;
}

pub fn get_response_by_request_seq(connection: *Connection, request_seq: i32) ?struct { Response, usize } {
    for (connection.expected_responses.items, 0..) |resp, i| {
        if (resp.request_seq == request_seq) return .{ resp, i };
    }

    return null;
}

pub fn get_event(connection: *Connection, name_or_seq: anytype) error{EventDoesNotExist}!struct { RawMessage, usize } {
    const T = @TypeOf(name_or_seq);
    const is_string = comptime utils.is_zig_string(T);
    if (T != i32 and !is_string) {
        @compileError("Event name_or_seq must be a []const u8 or an i32 found " ++ @typeName(T));
    }

    const key = if (T == i32) "seq" else "event";
    const wanted = if (T == i32) .integer else .string;
    for (connection.events.items, 0..) |event, i| {
        // messages shouldn't be queued up unless they're an object
        std.debug.assert(event.value == .object);
        const value = utils.get_value(event.value, key, wanted) orelse continue;
        if (T == i32) {
            if (name_or_seq == value) return .{ event, i };
        } else {
            if (std.mem.eql(u8, value, name_or_seq)) return .{ event, i };
        }
    }

    return error.EventDoesNotExist;
}

pub fn parse_validate_response(connection: *Connection, message: RawMessage, comptime T: type, request_seq: i32, command: Command) !std.json.Parsed(T) {
    const resp = try connection.parse_message(message, T);
    errdefer resp.deinit();

    try validate_response(resp.value, request_seq, command);

    return resp;
}

pub fn parse_event(connection: *Connection, message: RawMessage, comptime T: type, event: Event) !std.json.Parsed(T) {
    const e = utils.get_value(message.value, "event", .string) orelse @panic("Passed non-event message");
    std.debug.assert(std.mem.eql(u8, e, @tagName(event)));

    // this clones everything in the raw_event
    // const result = try std.json.parseFromValue(T, connection.allocator, message.value, .{ .ignore_unknown_fields = true });
    return connection.parse_message(message, T);
}

fn parse_message(connection: *Connection, message: RawMessage, comptime T: type) !std.json.Parsed(T) {
    if (!connection.debug) {
        return try std.json.parseFromValue(T, connection.allocator, message.value, .{ .ignore_unknown_fields = true });
    }

    var has_unknown_fields = false;
    const result = std.json.parseFromValue(
        T,
        connection.allocator,
        message.value,
        .{ .ignore_unknown_fields = false },
    ) catch |err| switch (err) {
        error.UnknownField => blk: {
            has_unknown_fields = true;
            break :blk try std.json.parseFromValue(
                T,
                connection.allocator,
                message.value,
                .{ .ignore_unknown_fields = true },
            );
        },

        error.OutOfMemory, error.Overflow, error.InvalidCharacter, error.UnexpectedToken, error.InvalidNumber, error.InvalidEnumTag, error.DuplicateField, error.MissingField, error.LengthMismatch => return err,
    };

    if (has_unknown_fields) {
        // since having debug flag enable this is memory safe
        // As long as we don't free it
        connection.debug_messages_with_unknown_fields.appendAssumeCapacity(message);
    }

    return result;
}

fn validate_response(resp: anytype, request_seq: i32, command: Command) !void {
    if (!resp.success) return error.RequestFailed;
    if (resp.request_seq != request_seq) return error.RequestResponseMismatchedRequestSeq;
    if (!std.mem.eql(u8, resp.command, @tagName(command))) return error.WrongCommandForResponse;
}

const Cloner = struct {
    data: *Connection,
    allocator: std.mem.Allocator,
    pub fn clone_string(cloner: Cloner, string: []const u8) ![]const u8 {
        return try cloner.allocator.dupe(u8, string);
    }
};

fn create_cloner(connection: *Connection) Cloner {
    return Cloner{
        .data = connection,
        .allocator = connection.arena.allocator(),
    };
}

const ClientCapabilitiesKind = enum {
    supportsVariableType,
    supportsVariablePaging,
    supportsRunInTerminalRequest,
    supportsMemoryReferences,
    supportsProgressReporting,
    supportsInvalidatedEvent,
    supportsMemoryEvent,
    supportsArgsCanBeInterpretedByShell,
    supportsStartDebuggingRequest,
    supportsANSIStyling,
};

const ClientCapabilitiesSet = std.EnumSet(ClientCapabilitiesKind);

pub const AdapterCapabilitiesKind = enum {
    supportsConfigurationDoneRequest,
    supportsFunctionBreakpoints,
    supportsConditionalBreakpoints,
    supportsHitConditionalBreakpoints,
    supportsEvaluateForHovers,
    supportsStepBack,
    supportsSetVariable,
    supportsRestartFrame,
    supportsGotoTargetsRequest,
    supportsStepInTargetsRequest,
    supportsCompletionsRequest,
    supportsModulesRequest,
    supportsRestartRequest,
    supportsExceptionOptions,
    supportsValueFormattingOptions,
    supportsExceptionInfoRequest,
    supportTerminateDebuggee,
    supportSuspendDebuggee,
    supportsDelayedStackTraceLoading,
    supportsLoadedSourcesRequest,
    supportsLogPoints,
    supportsTerminateThreadsRequest,
    supportsSetExpression,
    supportsTerminateRequest,
    supportsDataBreakpoints,
    supportsReadMemoryRequest,
    supportsWriteMemoryRequest,
    supportsDisassembleRequest,
    supportsCancelRequest,
    supportsBreakpointLocationsRequest,
    supportsClipboardContext,
    supportsSteppingGranularity,
    supportsInstructionBreakpoints,
    supportsExceptionFilterOptions,
    supportsSingleThreadExecutionRequests,
    supportsANSIStyling,
};
const AdapterCapabilitiesSet = std.EnumSet(AdapterCapabilitiesKind);

const AdapterCapabilities = struct {
    support: AdapterCapabilitiesSet = .{},
    completionTriggerCharacters: ?[][]const u8 = null,
    exceptionBreakpointFilters: ?[]protocol.ExceptionBreakpointsFilter = null,
    additionalModuleColumns: ?[]protocol.ColumnDescriptor = null,
    supportedChecksumAlgorithms: ?[]protocol.ChecksumAlgorithm = null,
    breakpointModes: ?[]protocol.BreakpointMode = null,
};

pub const RawMessage = std.json.Parsed(std.json.Value);

pub const RetainedRequestData = union(enum) {
    stack_trace: struct {
        thread_id: SessionData.ThreadID,
        request_scopes: bool,
        request_variables: bool,
    },
    scopes: struct {
        thread_id: SessionData.ThreadID,
        frame_id: SessionData.FrameID,
        request_variables: bool,
    },
    variables: struct {
        thread_id: SessionData.ThreadID,
        variables_reference: SessionData.VariableReference,
    },
    source: struct {
        path: ?[]const u8,
        source_reference: i32,
    },
    set_breakpoints: struct {
        source_id: SessionData.SourceID,
    },
    set_variable: struct {
        thread_id: SessionData.ThreadID,
        reference: SessionData.VariableReference,
        name: []const u8,
    },
    set_expression: struct {
        thread_id: SessionData.ThreadID,
        reference: SessionData.VariableReference,
        name: []const u8,
    },
    data_breakpoint_info: struct {
        name: []const u8,
        thread_id: SessionData.ThreadID,
        reference: ?SessionData.VariableReference,
        frame_id: ?SessionData.FrameID,
    },
    evaluate: struct {
        thread_id: SessionData.ThreadID,
        frame_id: SessionData.FrameID,
        expression: []const u8,
    },
    step_in_targets: struct {
        thread_id: SessionData.ThreadID,
        frame_id: SessionData.FrameID,
    },

    goto_targets: struct {
        source_id: SessionData.SourceID,
        line: i32,
    },
    no_data,
};

pub const Response = struct {
    command: Command,
    request_seq: i32,
    request_data: RetainedRequestData,
};

pub const ResponseStatus = enum { success, failure };
pub const HandledResponse = struct {
    response: Response,
    status: ResponseStatus,
    timestamp: i128,
};

pub const Request = struct {
    debug_request_seq: ?i32 = null,
    arena: std.heap.ArenaAllocator,
    args: protocol.Object,
    command: Command,
    request_data: RetainedRequestData,

    pub fn deinit(request: *Request) void {
        request.arena.deinit();
    }
};

pub const MessagesContext = struct {
    pub fn less_than(_: void, a: RawMessage, b: RawMessage) std.math.Order {
        const a_seq = utils.get_value(a.value, "seq", .integer) orelse @panic("Do only message with `seq` field should be queued");
        const b_seq = utils.get_value(b.value, "seq", .integer) orelse @panic("Do only message with `seq` field should be queued");

        return std.math.order(a_seq, b_seq);
    }
};
pub const Messages = std.PriorityQueue(RawMessage, void, MessagesContext.less_than);

pub const Command = blk: {
    @setEvalBranchQuota(10_000);

    const EnumField = std.builtin.Type.EnumField;
    var enum_fields: []const EnumField = &[_]EnumField{};
    var enum_value: usize = 0;

    for (std.meta.declarations(protocol)) |decl| {
        const T = @field(protocol, decl.name);
        if (@typeInfo(@TypeOf(T)) == .@"fn") continue;
        if (!std.mem.endsWith(u8, @typeName(T), "Request")) continue;
        if (!@hasField(T, "command")) @compileError("Request with no command!");

        for (std.meta.fields(T)) |field| {
            if (!std.mem.eql(u8, field.name, "command")) continue;
            if (@typeInfo(field.type) != .@"enum") continue;

            // fields of the type of "command"
            for (std.meta.fields(field.type)) |f| {
                enum_fields = enum_fields ++ &[_]EnumField{.{
                    .name = f.name,
                    .value = enum_value,
                }};
                enum_value += 1;
            }
        }
    }
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const HandledEvent = struct {
    event: Event,
    timestamp: i128,
};

pub const Event = blk: {
    @setEvalBranchQuota(10_000);

    const EnumField = std.builtin.Type.EnumField;
    var enum_fields: []const EnumField = &[_]EnumField{};
    var enum_value: usize = 0;

    for (std.meta.declarations(protocol)) |decl| {
        const T = @field(protocol, decl.name);
        if (@typeInfo(@TypeOf(T)) == .@"fn") continue;
        if (!std.mem.endsWith(u8, @typeName(T), "Event")) continue;
        if (!@hasField(T, "event")) @compileError("Event with no event!");

        for (std.meta.fields(T)) |field| {
            if (!std.mem.eql(u8, field.name, "event")) continue;
            if (@typeInfo(field.type) != .@"enum") continue;

            // fields of the type of "event"
            for (std.meta.fields(field.type)) |f| {
                enum_fields = enum_fields ++ &[_]EnumField{.{
                    .name = f.name,
                    .value = enum_value,
                }};
                enum_value += 1;
            }
        }
    }
    break :blk @Type(.{ .@"enum" = .{
        .tag_type = u8,
        .fields = enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    process: ?std.process.Child,
    id: []const u8,
    state: State,

    pub fn init(allocator: std.mem.Allocator) Adapter {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .process = null,
            .id = "",
            .state = .not_spawned,
        };
    }

    pub fn deinit(adapter: *Adapter) void {
        adapter.arena.deinit();
    }

    pub fn set(adapter: *Adapter, adapter_id: []const u8, argv: []const []const u8) !void {
        std.debug.assert(adapter.process == null);

        if (argv.len == 0) {
            return error.EmptyCommand;
        }

        if (!fs.path.isAbsolute(argv[0])) {
            return error.AdapterCommandIsNotAnAbsolutePath;
        }

        try io.file_touch(argv[0]);

        const cloned_id = try adapter.arena.allocator().dupe(u8, adapter_id);
        const cloned_argv = try adapter.arena.allocator().dupe([]const u8, argv);
        for (cloned_argv) |*arg| {
            arg.* = try adapter.arena.allocator().dupe(u8, arg.*);
        }
        adapter.process = std.process.Child.init(cloned_argv, adapter.allocator);
        adapter.process.?.stdin_behavior = .Pipe;
        adapter.process.?.stdout_behavior = .Pipe;
        adapter.process.?.stderr_behavior = .Pipe;
        adapter.id = cloned_id;
    }

    pub fn spawn(adapter: *Adapter) !void {
        std.debug.assert(adapter.process != null);

        switch (adapter.state) {
            .died, .not_spawned => {},

            .launched,
            .attached,
            .initialized,
            .partially_initialized,
            .initializing,
            .spawned,
            => return error.AdapterAlreadySpawned,
        }

        try adapter.process.?.spawn();
        adapter.state = .spawned;
    }

    pub fn write_all(adapter: *Adapter, message: []const u8) !void {
        std.debug.assert(adapter.state != .not_spawned);
        std.debug.assert(adapter.process != null);
        const stdin = adapter.process.?.stdin orelse return;
        try stdin.writer().writeAll(message);
    }

    const State = enum {
        /// Adapter and debuggee are running
        launched,
        /// Adapter and debuggee are running
        attached,
        /// Adapter is running and the initialized event has been handled
        initialized,
        /// Adapter is running and the initialize request has been responded to
        partially_initialized,
        /// Adapter is running and the initialize request has been sent
        initializing,
        /// Adapter is running
        spawned,
        /// Adapter is not running
        not_spawned,
        /// RIP
        died,

        pub fn fully_initialized(state: State) bool {
            return switch (state) {
                .initialized, .launched, .attached => true,

                .died, .partially_initialized, .initializing, .spawned, .not_spawned => false,
            };
        }

        pub fn accepts_requests(state: State) bool {
            return switch (state) {
                .initialized,
                .launched,
                .attached,
                .partially_initialized,
                .initializing,
                .spawned,
                => true,

                .died, .not_spawned => false,
            };
        }
    };
};
