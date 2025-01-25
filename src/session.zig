const std = @import("std");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const io = @import("io.zig");

const log = std.log.scoped(.session);

const Session = @This();

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

/// Used for the seq field in the protocol
seq: u32 = 1,

pub fn init(allocator: std.mem.Allocator, adapter_argv: []const []const u8) Session {
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
        .responses = std.ArrayList(RawMessage).init(allocator),
        .handled_responses = std.ArrayList(RawMessage).init(allocator),
        .events = std.ArrayList(RawMessage).init(allocator),
        .handled_events = std.ArrayList(RawMessage).init(allocator),
    };
}

pub fn end_session(session: *Session, how: enum { terminate, disconnect }) !i32 {
    switch (session.start_kind) {
        .not_started => return error.SessionNotStarted,
        .attached => @panic("TODO"),
        .launched => {
            switch (how) {
                .terminate => return try session.send_terminate_request(false),
                .disconnect => return try session.send_disconnect_request(false),
            }
        },
    }
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn send_init_request(session: *Session, arguments: protocol.InitializeRequestArguments, extra_arguments: protocol.Object) !i32 {
    const request = protocol.InitializeRequest{
        .seq = session.new_seq(),
        .type = .request,
        .command = .initialize,
        .arguments = arguments,
    };

    session.client_capabilities = utils.bit_set_from_struct(arguments, ClientCapabilitiesSet, ClientCapabilitiesKind);

    try session.value_to_object_then_inject_then_write(request, &.{"arguments"}, extra_arguments);

    return request.seq;
}

pub fn handle_init_response(session: *Session, seq: i32) !void {
    const resp = try session.get_and_parse_response(protocol.InitializeResponse, seq);
    defer {
        session.delete_response(seq);
        resp.deinit();
    }
    try validate_response(resp.value, seq, "initialize");
    if (resp.value.body) |body| {
        session.adapter_capabilities.support = utils.bit_set_from_struct(body, AdapterCapabilitiesSet, AdapterCapabilitiesKind);
        session.adapter_capabilities.completionTriggerCharacters = body.completionTriggerCharacters;
        session.adapter_capabilities.exceptionBreakpointFilters = body.exceptionBreakpointFilters;
        session.adapter_capabilities.additionalModuleColumns = body.additionalModuleColumns;
        session.adapter_capabilities.supportedChecksumAlgorithms = body.supportedChecksumAlgorithms;
        session.adapter_capabilities.breakpointModes = body.breakpointModes;
    }
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn send_launch_request(session: *Session, arguments: protocol.LaunchRequestArguments, extra_arguments: protocol.Object) !i32 {
    const request = protocol.LaunchRequest{
        .seq = session.new_seq(),
        .type = .request,
        .command = .launch,
        .arguments = arguments,
    };

    try session.value_to_object_then_inject_then_write(request, &.{"arguments"}, extra_arguments);
    return request.seq;
}

pub fn handle_launch_response(session: *Session, seq: i32) !void {
    std.debug.assert(session.start_kind == .not_started);
    const resp = try session.get_parse_validate_response(protocol.LaunchResponse, seq, "launch");
    defer resp.deinit();
    session.start_kind = .launched;
    session.delete_response(seq);
}

pub fn send_configuration_done_request(session: *Session, arguments: ?protocol.ConfigurationDoneArguments, extra_arguments: protocol.Object) !i32 {
    if (!session.adapter_capabilities.support.contains(.supportsConfigurationDoneRequest)) {
        return error.AdapterDoesNotSupportConfigurationDone;
    }

    const request = protocol.ConfigurationDoneRequest{
        .seq = session.new_seq(),
        .type = .request,
        .command = .configurationDone,
        .arguments = arguments,
    };

    try session.value_to_object_then_inject_then_write(request, &.{"arguments"}, extra_arguments);
    return request.seq;
}

pub fn handle_configuration_done_response(session: *Session, seq: i32) !void {
    const resp = try session.get_parse_validate_response(protocol.ConfigurationDoneResponse, seq, "configurationDone");
    defer resp.deinit();
    session.delete_response(seq);
}

fn send_terminate_request(session: *Session, restart: ?bool) !i32 {
    if (!session.adapter_capabilities.support.contains(.supportsTerminateRequest)) {
        return error.AdapterDoesNotSupportTerminate;
    }

    const request = protocol.TerminateRequest{
        .seq = session.new_seq(),
        .type = .request,
        .command = .terminate,
        .arguments = .{
            .restart = restart,
        },
    };

    try session.value_to_object_then_write(request);

    return request.seq;
}

fn send_disconnect_request(session: *Session, restart: ?bool) !i32 {
    const request = protocol.DisconnectRequest{
        .seq = session.new_seq(),
        .type = .request,
        .command = .disconnect,
        .arguments = .{
            .restart = restart,
            // TODO: figure out when to set all of these
            .terminateDebuggee = null,
            .suspendDebuggee = null,
        },
    };

    try session.value_to_object_then_write(request);

    return request.seq;
}

pub fn handle_disconnect_response(session: *Session, seq: i32) !void {
    const resp = try session.get_and_parse_response(protocol.DisconnectResponse, seq);
    try validate_response(resp.value, seq, "disconnect");

    if (resp.value.success) {
        session.start_kind = .not_started;
    }

    session.delete_response(seq);
}

pub fn send_threads_request(session: *Session, arguments: ?protocol.Value) !i32 {
    const request = protocol.ThreadsRequest{
        .seq = session.new_seq(),
        .type = .request,
        .command = .threads,
        .arguments = arguments,
    };

    try session.value_to_object_then_write(request);
    return request.seq;
}

pub fn response_handled_threads(session: *Session, seq: i32) !void {
    const resp = try session.get_parse_validate_response(protocol.ThreadsResponse, seq, "threads");
    defer resp.deinit();
    session.delete_response(seq);
}

pub fn event_handled_terminated(session: *Session, seq: i32) !void {
    _, const index = try session.get_event(seq);
    session.delete_event_by_index(index);
}

pub fn event_handled_modules(session: *Session, seq: i32) !void {
    _, const index = try session.get_event(seq);
    session.delete_event_by_index(index);
}

pub fn handle_initialized_event(session: *Session) !void {
    _, const index = try session.get_event("initialized");
    session.delete_event_by_index(index);
}

pub fn event_handled_output(session: *Session, seq: i32) !void {
    _, const index = try session.get_event(seq);
    session.delete_event_by_index(index);
}

pub fn adapter_spawn(session: *Session) !void {
    _ = try session.adapter.spawn();
}

pub fn adapter_wait(session: *Session) !void {
    _ = try session.adapter.wait();
}

pub fn adapter_write_all(session: *Session, message: []const u8) !void {
    try session.adapter.stdin.?.writer().writeAll(message);
}

pub fn new_seq(s: *Session) i32 {
    const seq = s.seq;
    s.seq += 1;
    return @intCast(seq);
}

pub fn queue_messages(session: *Session, timeout_ms: u64) !void {
    const stdout = session.adapter.stdout orelse return;
    if (try io.message_exists(stdout, session.allocator, timeout_ms)) {
        try session.responses.ensureUnusedCapacity(1);
        try session.handled_responses.ensureTotalCapacity(session.total_responses_received + 1);

        try session.events.ensureUnusedCapacity(1);
        try session.handled_events.ensureTotalCapacity(session.total_events_received + 1);

        const parsed = try io.read_message(stdout, session.allocator);
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
            session.responses.appendAssumeCapacity(parsed);
            session.total_responses_received += 1;
        } else if (std.mem.eql(u8, string, "event")) {
            const name = utils.pull_value(object.get("event"), .string) orelse "";
            log.debug("New event \"{s}\"", .{name});
            session.events.appendAssumeCapacity(parsed);
            session.total_events_received += 1;
        } else {
            return error.UnknownMessage;
        }
    }
}

pub fn get_response(session: *Session, request_seq: i32) !struct { RawMessage, usize } {
    for (session.responses.items, 0..) |resp, i| {
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

pub fn get_event(session: *Session, name_or_seq: anytype) !struct { RawMessage, usize } {
    const T = @TypeOf(name_or_seq);
    const is_string = comptime utils.is_zig_string(T);
    if (T != i32 and !is_string) {
        @compileError("Event name_or_seq must be a []const u8 or an i32 found " ++ @typeName(T));
    }

    const key = if (T == i32) "seq" else "event";
    const wanted = if (T == i32) .integer else .string;
    for (session.events.items, 0..) |event, i| {
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

fn delete_response(session: *Session, request_seq: i32) void {
    _, const index = session.get_response(request_seq) catch @panic("Only call this if you got a response");
    const raw_resp = session.responses.swapRemove(index);
    session.handled_responses.appendAssumeCapacity(raw_resp);
}

fn delete_event_by_seq(session: *Session, event_seq: i32) void {
    _, const index = session.get_event(event_seq) catch @panic("Only call this if you got an event");
    session.delete_event_by_index(index);
}

fn delete_event_by_index(session: *Session, index: usize) void {
    const raw_event = session.events.swapRemove(index);
    session.handled_events.appendAssumeCapacity(raw_event);
}

fn value_to_object_then_write(session: *Session, value: anytype) !void {
    try session.value_to_object_then_inject_then_write(value, &.{}, .{});
}

fn value_to_object_then_inject_then_write(session: *Session, value: anytype, ancestors: []const []const u8, extra: protocol.Object) !void {
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

    const message = try io.create_message(session.allocator, object);
    try session.adapter_write_all(message);
}

pub fn wait_for_response(session: *Session, seq: i32) !void {
    while (true) {
        for (session.responses.items) |item| {
            const request_seq = utils.pull_value(item.value.object.get("request_seq"), .integer) orelse continue;
            if (request_seq == seq) {
                return;
            }
        }
        try session.queue_messages(std.time.ms_per_s);
    }
}

pub fn wait_for_event(session: *Session, name: []const u8) !void {
    while (true) {
        try session.queue_messages(std.time.ms_per_s);
        for (session.events.items) |item| {
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

pub fn get_and_parse_response(session: *Session, comptime T: type, seq: i32) !std.json.Parsed(T) {
    const raw_resp, _ = try session.get_response(seq);
    return try std.json.parseFromValue(T, session.allocator, raw_resp.value, .{});
}

pub fn get_parse_validate_response(session: *Session, comptime T: type, seq: i32, command: []const u8) !std.json.Parsed(T) {
    const raw_resp, _ = try session.get_response(seq);
    const resp = try std.json.parseFromValue(T, session.allocator, raw_resp.value, .{});
    try validate_response(resp.value, seq, command);

    return resp;
}

pub fn get_and_parse_event(session: *Session, comptime T: type, name: []const u8) !std.json.Parsed(T) {
    const raw_event, _ = try session.get_event(name);
    // this clones everything in the raw_event
    return try std.json.parseFromValue(T, session.allocator, raw_event.value, .{});
}

fn validate_response(resp: anytype, seq: i32, command: []const u8) !void {
    if (!resp.success) return error.RequestFailed;
    if (resp.request_seq != seq) return error.RequestResponseMismatchedSeq;
    if (!std.mem.eql(u8, resp.command, command)) return error.WrongCommandForResponse;
}
