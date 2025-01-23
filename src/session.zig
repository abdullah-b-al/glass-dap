const std = @import("std");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const io = @import("io.zig");

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
    try session.queue_messages(std.time.ns_per_ms * 10);
    const raw_resp = (try session.get_response(seq)).?;
    defer session.delete_response(seq);
    const parsed_resp = try std.json.parseFromValue(protocol.InitializeResponse, session.allocator, raw_resp.value, .{});
    defer parsed_resp.deinit();
    const resp = parsed_resp.value;
    std.debug.assert(resp.success);
    std.debug.assert(resp.request_seq == seq);
    std.debug.assert(std.mem.eql(u8, resp.command, "initialize"));
    if (resp.body) |body| {
        session.adapter_capabilities.support = utils.bit_set_from_struct(body, AdapterCapabilitiesSet, AdapterCapabilitiesKind);
        session.adapter_capabilities.completionTriggerCharacters = body.completionTriggerCharacters;
        session.adapter_capabilities.exceptionBreakpointFilters = body.exceptionBreakpointFilters;
        session.adapter_capabilities.additionalModuleColumns = body.additionalModuleColumns;
        session.adapter_capabilities.supportedChecksumAlgorithms = body.supportedChecksumAlgorithms;
        session.adapter_capabilities.breakpointModes = body.breakpointModes;
    }
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn send_launch_request(session: *Session, arguments: protocol.LaunchRequestArguments, extra_arguments: protocol.Object) !void {
    const request = protocol.LaunchRequest{
        .seq = session.new_seq(),
        .type = .request,
        .command = .launch,
        .arguments = arguments,
    };

    try session.value_to_object_then_inject_then_write(request, &.{"arguments"}, extra_arguments);
}

pub fn send_configuration_done_request(session: *Session, arguments: ?protocol.ConfigurationDoneArguments, extra_arguments: protocol.Object) !void {
    const request = protocol.ConfigurationDoneRequest{
        .seq = session.new_seq(),
        .type = .request,
        .command = .configurationDone,
        .arguments = arguments,
    };

    try session.value_to_object_then_inject_then_write(request, &.{"arguments"}, extra_arguments);
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

pub fn queue_messages(session: *Session, timeout: u64) !void {
    if (try io.message_exists(session.adapter.stdout.?, session.allocator, timeout)) {
        try session.responses.ensureUnusedCapacity(1);
        try session.handled_responses.ensureUnusedCapacity(1);
        try session.events.ensureUnusedCapacity(1);

        const parsed = try io.read_message(session.adapter.stdout.?, session.allocator);
        errdefer {
            std.log.err("{}\n", .{parsed});
            parsed.deinit();
        }
        if (parsed.value != .object) return error.InvalidMessage;
        const t = parsed.value.object.get("type") orelse return error.InvalidMessage;
        if (t != .string) return error.InvalidMessage;
        const string = t.string;

        if (std.mem.eql(u8, string, "response")) {
            session.responses.appendAssumeCapacity(parsed);
        } else if (std.mem.eql(u8, string, "event")) {
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
        const raw_seq = object.get("request_seq") orelse return null;
        const seq = switch (raw_seq) {
            .integer => |int| int,
            else => return error.InvalidSaqFromAdapter,
        };
        if (seq == request_seq) return i;
    }

    return null;
}

fn delete_response(session: *Session, request_seq: i32) void {
    const i = (session.get_response_index(request_seq) catch unreachable).?;
    const raw_resp = session.responses.swapRemove(i);
    session.handled_responses.appendAssumeCapacity(raw_resp);
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
