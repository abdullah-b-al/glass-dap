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

const RawResponse = std.json.Parsed(std.json.Value);

allocator: std.mem.Allocator,
adapter: std.process.Child,

client_capabilities: ClientCapabilitiesSet = .{},
adapter_capabilities: AdapterCapabilities = .{},

responses: std.ArrayList(RawResponse),
handled_responses: std.ArrayList(RawResponse),

events: std.ArrayList(RawResponse),
handled_events: std.ArrayList(RawResponse),

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
        .adapter = adapter,
        .allocator = allocator,
        .responses = std.ArrayList(RawResponse).init(allocator),
        .handled_responses = std.ArrayList(RawResponse).init(allocator),
        .events = std.ArrayList(RawResponse).init(allocator),
        .handled_events = std.ArrayList(RawResponse).init(allocator),
    };
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
    const resp = try session.get_and_parse_response(protocol.LaunchResponse, seq);
    try validate_response(resp.value, seq, "launch");
    session.delete_response(seq);
}

pub fn send_configuration_done_request(session: *Session, arguments: ?protocol.ConfigurationDoneArguments, extra_arguments: protocol.Object) !i32 {
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
    const resp = try session.get_and_parse_response(protocol.ConfigurationDoneResponse, seq);
    try validate_response(resp.value, seq, "configurationDone");
    session.delete_response(seq);
}

pub fn handle_initialized_event(session: *Session) !void {
    _, const index = (try session.get_event_by_name("initialized")) orelse return error.EventDoseNotExist;
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
    if (try io.message_exists(session.adapter.stdout.?, session.allocator, timeout_ms)) {
        try session.responses.ensureUnusedCapacity(1);
        try session.handled_responses.ensureUnusedCapacity(1);
        try session.events.ensureUnusedCapacity(1);
        try session.handled_events.ensureUnusedCapacity(1);

        const parsed = try io.read_message(session.adapter.stdout.?, session.allocator);
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
        } else if (std.mem.eql(u8, string, "event")) {
            const name = utils.pull_value(object.get("event"), .string) orelse "";
            log.debug("New event \"{s}\"", .{name});
            session.events.appendAssumeCapacity(parsed);
        } else {
            return error.UnknownMessage;
        }
    }
}

fn get_response(session: *Session, request_seq: i32) !?RawResponse {
    const i = try session.get_response_index(request_seq) orelse return null;
    return session.responses.items[i];
}

fn get_response_index(session: *Session, request_seq: i32) !?usize {
    for (session.responses.items, 0..) |resp, i| {
        const object = resp.value.object; // messages shouldn't be queued up unless they're an object
        const raw_seq = object.get("request_seq") orelse continue;
        const seq = switch (raw_seq) {
            .integer => |int| int,
            else => return error.InvalidSeqFromAdapter,
        };
        if (seq == request_seq) return i;
    }

    return null;
}

fn get_event_by_name(session: *Session, event_name: []const u8) !?struct { RawResponse, usize } {
    for (session.events.items, 0..) |event, i| {
        const object = event.value.object; // messages shouldn't be queued up unless they're an object
        const raw_seq = object.get("event") orelse continue;
        const name = switch (raw_seq) {
            .string => |string| string,
            else => return error.InvalidSeqFromAdapter,
        };
        if (std.mem.eql(u8, name, event_name)) return .{ event, i };
    }

    return null;
}

fn get_event_index(session: *Session, event_seq: i32) !?usize {
    for (session.events.items, 0..) |event, i| {
        const object = event.value.object; // messages shouldn't be queued up unless they're an object
        const raw_seq = object.get("seq") orelse continue;
        const seq = switch (raw_seq) {
            .integer => |int| int,
            else => return error.InvalidSeqFromAdapter,
        };
        if (seq == event_seq) return i;
    }

    return null;
}

fn delete_response(session: *Session, request_seq: i32) void {
    const i = (session.get_response_index(request_seq) catch unreachable).?;
    const raw_resp = session.responses.swapRemove(i);
    session.handled_responses.appendAssumeCapacity(raw_resp);
}

fn delete_event(session: *Session, event_seq: i32) void {
    const i = (session.get_event_index(event_seq) catch unreachable).?;
    session.delete_event_by_index(i);
}

fn delete_event_by_index(session: *Session, index: usize) void {
    const raw_event = session.events.swapRemove(index);
    session.handled_events.appendAssumeCapacity(raw_event);
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

fn get_and_parse_response(session: *Session, comptime T: type, seq: i32) !std.json.Parsed(T) {
    const raw_resp = (try session.get_response(seq)) orelse return error.ResponseDoesNotExist;
    return try std.json.parseFromValue(T, session.allocator, raw_resp.value, .{});
}

fn validate_response(resp: anytype, seq: i32, command: []const u8) !void {
    if (!resp.success) return error.RequestFailed;
    if (resp.request_seq != seq) return error.RequestResponseMismatchedSeq;
    if (!std.mem.eql(u8, resp.command, command)) return error.WrongCommandForResponse;
}
