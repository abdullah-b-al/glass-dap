const std = @import("std");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const io = @import("io.zig");

const log = std.log.scoped(.connection);

const Connection = @This();

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

const AdapterCapabilitiesKind = enum {
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

const RawMessage = std.json.Parsed(std.json.Value);

const StartKind = enum { launched, attached, not_started };

allocator: std.mem.Allocator,
/// Used for deeply cloned values
arena: std.heap.ArenaAllocator,
adapter: std.process.Child,

client_capabilities: ClientCapabilitiesSet = .{},
adapter_capabilities: AdapterCapabilities = .{},

total_responses_received: u32 = 0,
responses: std.ArrayList(RawMessage),
handled_responses: std.ArrayList(RawMessage),

total_events_received: u32 = 0,
events: std.ArrayList(RawMessage),
handled_events: std.ArrayList(RawMessage),

start_kind: StartKind,
debug: bool,

/// Used for the seq field in the protocol
seq: u32 = 1,

pub fn init(allocator: std.mem.Allocator, adapter_argv: []const []const u8, debug: bool) Connection {
    var adapter = std.process.Child.init(
        adapter_argv,
        allocator,
    );

    adapter.stdin_behavior = .Pipe;
    adapter.stdout_behavior = .Pipe;
    adapter.stderr_behavior = .Pipe;

    return .{
        .start_kind = .not_started,
        .adapter = adapter,
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .responses = std.ArrayList(RawMessage).init(allocator),
        .handled_responses = std.ArrayList(RawMessage).init(allocator),
        .events = std.ArrayList(RawMessage).init(allocator),
        .handled_events = std.ArrayList(RawMessage).init(allocator),
        .debug = debug,
    };
}

pub fn deinit(connection: *Connection) void {
    const table = .{
        connection.responses.items,
        connection.handled_responses.items,
        connection.events.items,
        connection.handled_events.items,
    };

    inline for (table) |entry| {
        for (entry) |*item| {
            item.deinit();
        }
    }

    connection.responses.deinit();
    connection.handled_responses.deinit();
    connection.events.deinit();
    connection.handled_events.deinit();

    connection.arena.deinit();
}

pub fn end_session(connection: *Connection, how: enum { terminate, disconnect }) !i32 {
    switch (connection.start_kind) {
        .not_started => return error.SessionNotStarted,
        .attached => @panic("TODO"),
        .launched => {
            switch (how) {
                .terminate => return try connection.send_terminate_request(false),
                .disconnect => return try connection.send_disconnect_request(false),
            }
        },
    }
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn send_init_request(connection: *Connection, arguments: protocol.InitializeRequestArguments, extra_arguments: protocol.Object) !i32 {
    const request = protocol.InitializeRequest{
        .seq = connection.new_seq(),
        .type = .request,
        .command = .initialize,
        .arguments = arguments,
    };

    connection.client_capabilities = utils.bit_set_from_struct(arguments, ClientCapabilitiesSet, ClientCapabilitiesKind);

    try connection.value_to_object_then_inject_then_write(request, &.{"arguments"}, extra_arguments);

    return request.seq;
}

pub fn handle_init_response(connection: *Connection, seq: i32) !void {
    const cloner = connection.create_cloner();

    const resp = try connection.get_and_parse_response(protocol.InitializeResponse, seq);
    defer {
        connection.delete_response(seq);
        resp.deinit();
    }
    try validate_response(resp.value, seq, "initialize");
    if (resp.value.body) |body| {
        connection.adapter_capabilities.support = utils.bit_set_from_struct(body, AdapterCapabilitiesSet, AdapterCapabilitiesKind);
        connection.adapter_capabilities.completionTriggerCharacters = try utils.clone_anytype(cloner, body.completionTriggerCharacters);
        connection.adapter_capabilities.exceptionBreakpointFilters = try utils.clone_anytype(cloner, body.exceptionBreakpointFilters);
        connection.adapter_capabilities.additionalModuleColumns = try utils.clone_anytype(cloner, body.additionalModuleColumns);
        connection.adapter_capabilities.supportedChecksumAlgorithms = try utils.clone_anytype(cloner, body.supportedChecksumAlgorithms);
        connection.adapter_capabilities.breakpointModes = try utils.clone_anytype(cloner, body.breakpointModes);
    }
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn send_launch_request(connection: *Connection, arguments: protocol.LaunchRequestArguments, extra_arguments: protocol.Object) !i32 {
    const request = protocol.LaunchRequest{
        .seq = connection.new_seq(),
        .type = .request,
        .command = .launch,
        .arguments = arguments,
    };

    try connection.value_to_object_then_inject_then_write(request, &.{"arguments"}, extra_arguments);
    return request.seq;
}

pub fn handle_launch_response(connection: *Connection, seq: i32) !void {
    std.debug.assert(connection.start_kind == .not_started);
    const resp = try connection.get_parse_validate_response(protocol.LaunchResponse, seq, "launch");
    defer resp.deinit();
    connection.start_kind = .launched;
    connection.delete_response(seq);
}

pub fn send_configuration_done_request(connection: *Connection, arguments: ?protocol.ConfigurationDoneArguments, extra_arguments: protocol.Object) !i32 {
    if (!connection.adapter_capabilities.support.contains(.supportsConfigurationDoneRequest)) {
        return error.AdapterDoesNotSupportConfigurationDone;
    }

    const request = protocol.ConfigurationDoneRequest{
        .seq = connection.new_seq(),
        .type = .request,
        .command = .configurationDone,
        .arguments = arguments,
    };

    try connection.value_to_object_then_inject_then_write(request, &.{"arguments"}, extra_arguments);
    return request.seq;
}

pub fn handle_configuration_done_response(connection: *Connection, seq: i32) !void {
    const resp = try connection.get_parse_validate_response(protocol.ConfigurationDoneResponse, seq, "configurationDone");
    defer resp.deinit();
    connection.delete_response(seq);
}

fn send_terminate_request(connection: *Connection, restart: ?bool) !i32 {
    if (!connection.adapter_capabilities.support.contains(.supportsTerminateRequest)) {
        return error.AdapterDoesNotSupportTerminate;
    }

    const request = protocol.TerminateRequest{
        .seq = connection.new_seq(),
        .type = .request,
        .command = .terminate,
        .arguments = .{
            .restart = restart,
        },
    };

    try connection.value_to_object_then_write(request);

    return request.seq;
}

fn send_disconnect_request(connection: *Connection, restart: ?bool) !i32 {
    const request = protocol.DisconnectRequest{
        .seq = connection.new_seq(),
        .type = .request,
        .command = .disconnect,
        .arguments = .{
            .restart = restart,
            // TODO: figure out when to set all of these
            .terminateDebuggee = null,
            .suspendDebuggee = null,
        },
    };

    try connection.value_to_object_then_write(request);

    return request.seq;
}

pub fn handle_disconnect_response(connection: *Connection, seq: i32) !void {
    const resp = try connection.get_and_parse_response(protocol.DisconnectResponse, seq);
    defer resp.deinit();
    try validate_response(resp.value, seq, "disconnect");

    if (resp.value.success) {
        connection.start_kind = .not_started;
    }

    connection.delete_response(seq);
}

pub fn send_threads_request(connection: *Connection, arguments: ?protocol.Value) !i32 {
    const request = protocol.ThreadsRequest{
        .seq = connection.new_seq(),
        .type = .request,
        .command = .threads,
        .arguments = arguments,
    };

    try connection.value_to_object_then_write(request);
    return request.seq;
}

pub fn response_handled_threads(connection: *Connection, seq: i32) !void {
    const resp = try connection.get_parse_validate_response(protocol.ThreadsResponse, seq, "threads");
    defer resp.deinit();
    connection.delete_response(seq);
}

pub fn event_handled_terminated(connection: *Connection, seq: i32) !void {
    connection.delete_event(seq);
}

pub fn event_handled_modules(connection: *Connection, seq: i32) !void {
    connection.delete_event(seq);
}

pub fn handle_initialized_event(connection: *Connection) !void {
    const event = try connection.get_and_parse_event(protocol.InitializedEvent, "initialized");
    defer event.deinit();

    connection.delete_event(event.value.seq);
}

pub fn event_handled_output(connection: *Connection, seq: i32) !void {
    connection.delete_event(seq);
}

pub fn adapter_spawn(connection: *Connection) !void {
    _ = try connection.adapter.spawn();
}

pub fn adapter_wait(connection: *Connection) !void {
    _ = try connection.adapter.wait();
}

pub fn adapter_write_all(connection: *Connection, message: []const u8) !void {
    try connection.adapter.stdin.?.writer().writeAll(message);
}

pub fn new_seq(s: *Connection) i32 {
    const seq = s.seq;
    s.seq += 1;
    return @intCast(seq);
}

pub fn queue_messages(connection: *Connection, timeout_ms: u64) !void {
    const stdout = connection.adapter.stdout orelse return;
    if (try io.message_exists(stdout, connection.allocator, timeout_ms)) {
        try connection.responses.ensureUnusedCapacity(1);
        try connection.handled_responses.ensureTotalCapacity(connection.total_responses_received + 1);

        try connection.events.ensureUnusedCapacity(1);
        try connection.handled_events.ensureTotalCapacity(connection.total_events_received + 1);

        const parsed = try io.read_message(stdout, connection.allocator);
        errdefer {
            std.log.err("{}\n", .{parsed});
            parsed.deinit();
        }
        const object = if (parsed.value == .object) parsed.value.object else return error.InvalidMessage;
        const t = object.get("type") orelse return error.InvalidMessage;
        if (t != .string) return error.InvalidMessage;
        const string = t.string;

        if (std.mem.eql(u8, string, "response")) {
            const name = utils.pull_value(object.get("command"), .string) orelse "";
            log.debug("New response \"{s}\"", .{name});
            connection.responses.appendAssumeCapacity(parsed);
            connection.total_responses_received += 1;
        } else if (std.mem.eql(u8, string, "event")) {
            const name = utils.pull_value(object.get("event"), .string) orelse "";
            log.debug("New event \"{s}\"", .{name});
            connection.events.appendAssumeCapacity(parsed);
            connection.total_events_received += 1;
        } else {
            return error.UnknownMessage;
        }
    }
}

pub fn get_response(connection: *Connection, request_seq: i32) !struct { RawMessage, usize } {
    for (connection.responses.items, 0..) |resp, i| {
        const object = resp.value.object; // messages shouldn't be queued up unless they're an object
        const raw_seq = object.get("request_seq") orelse continue;
        const seq = switch (raw_seq) {
            .integer => |int| int,
            else => return error.InvalidSeqFromAdapter,
        };
        if (seq == request_seq) {
            return .{ resp, i };
        }
    }

    return error.ResponseDoesNotExist;
}

pub fn get_event(connection: *Connection, name_or_seq: anytype) error{EventDoseNotExist}!struct { RawMessage, usize } {
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

    return error.EventDoseNotExist;
}

fn delete_response(connection: *Connection, request_seq: i32) void {
    _, const index = connection.get_response(request_seq) catch @panic("Only call this if you got a response");
    const raw_resp = connection.responses.orderedRemove(index);
    if (connection.debug) {
        connection.handled_responses.appendAssumeCapacity(raw_resp);
    } else {
        raw_resp.deinit();
    }
}

fn delete_event(connection: *Connection, event_seq: i32) void {
    _, const index = connection.get_event(event_seq) catch @panic("Only call this if you got an event");
    const raw_event = connection.events.orderedRemove(index);
    if (connection.debug) {
        connection.handled_events.appendAssumeCapacity(raw_event);
    } else {
        raw_event.deinit();
    }
}

fn value_to_object_then_write(connection: *Connection, value: anytype) !void {
    try connection.value_to_object_then_inject_then_write(value, &.{}, .{});
}

fn value_to_object_then_inject_then_write(connection: *Connection, value: anytype, ancestors: []const []const u8, extra: protocol.Object) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var object = try utils.value_to_object(arena.allocator(), value);
    if (extra.map.count() > 0) {
        var ancestor = try utils.object_ancestor_get(&object, ancestors);
        var iter = extra.map.iterator();
        while (iter.next()) |entry| {
            try ancestor.map.put(arena.allocator(), entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    const message = try io.create_message(connection.allocator, object);
    defer connection.allocator.free(message);
    try connection.adapter_write_all(message);
}

pub fn wait_for_response(connection: *Connection, seq: i32) !void {
    while (true) {
        for (connection.responses.items) |item| {
            const request_seq = utils.pull_value(item.value.object.get("request_seq"), .integer) orelse continue;
            if (request_seq == seq) {
                return;
            }
        }
        try connection.queue_messages(std.time.ms_per_s);
    }
}

pub fn wait_for_event(connection: *Connection, name: []const u8) !void {
    while (true) {
        try connection.queue_messages(std.time.ms_per_s);
        for (connection.events.items) |item| {
            const value_event = item.value.object.get("event").?;
            const event = switch (value_event) {
                .string => |string| string,
                else => unreachable, // this shouldn't run unless the message is invalid
            };
            if (std.mem.eql(u8, name, event)) {
                return;
            }
        }
    }
}

pub fn get_and_parse_response(connection: *Connection, comptime T: type, seq: i32) !std.json.Parsed(T) {
    const raw_resp, _ = try connection.get_response(seq);
    return try std.json.parseFromValue(T, connection.allocator, raw_resp.value, .{});
}

pub fn get_parse_validate_response(connection: *Connection, comptime T: type, seq: i32, command: []const u8) !std.json.Parsed(T) {
    const raw_resp, _ = try connection.get_response(seq);
    const resp = try std.json.parseFromValue(T, connection.allocator, raw_resp.value, .{});
    try validate_response(resp.value, seq, command);

    return resp;
}

pub fn get_and_parse_event(connection: *Connection, comptime T: type, name: []const u8) !std.json.Parsed(T) {
    const raw_event, _ = try connection.get_event(name);
    // this clones everything in the raw_event
    return try std.json.parseFromValue(T, connection.allocator, raw_event.value, .{});
}

fn validate_response(resp: anytype, seq: i32, command: []const u8) !void {
    if (!resp.success) return error.RequestFailed;
    if (resp.request_seq != seq) return error.RequestResponseMismatchedSeq;
    if (!std.mem.eql(u8, resp.command, command)) return error.WrongCommandForResponse;
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
