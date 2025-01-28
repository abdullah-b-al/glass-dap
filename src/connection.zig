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

    pub fn fully_initialized(state: State) bool {
        return switch (state) {
            .initialized, .launched, .attached => true,

            .partially_initialized, .initializing, .spawned, .not_spawned => false,
        };
    }
};

const Dependency = union(enum) {
    response: Command,
    event: Event,
    seq: i32,
    none,
};

pub const Response = struct {
    command: Command,
    request_seq: i32,
    success: bool,
};

pub const Request = struct {
    arena: std.heap.ArenaAllocator,
    object: protocol.Object,
    command: Command,
    seq: i32,
    /// Send request when dependency is satisfied
    depends_on: Dependency,
};

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

allocator: std.mem.Allocator,
/// Used for deeply cloned values
arena: std.heap.ArenaAllocator,
adapter: std.process.Child,

client_capabilities: ClientCapabilitiesSet = .{},
adapter_capabilities: AdapterCapabilities = .{},

queued_requests: std.ArrayList(Request),
expected_responses: std.ArrayList(Response),
handled_responses: std.ArrayList(Response),
handled_events: std.ArrayList(Event),

total_responses_received: u32 = 0,
responses: std.ArrayList(RawMessage),
debug_handled_responses: std.ArrayList(RawMessage),

total_events_received: u32 = 0,
events: std.ArrayList(RawMessage),
debug_handled_events: std.ArrayList(RawMessage),

state: State,
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
        .state = .not_spawned,
        .adapter = adapter,
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        .queued_requests = std.ArrayList(Request).init(allocator),
        .responses = std.ArrayList(RawMessage).init(allocator),
        .expected_responses = std.ArrayList(Response).init(allocator),
        .handled_responses = std.ArrayList(Response).init(allocator),
        .handled_events = std.ArrayList(Event).init(allocator),

        .debug_handled_responses = std.ArrayList(RawMessage).init(allocator),
        .events = std.ArrayList(RawMessage).init(allocator),
        .debug_handled_events = std.ArrayList(RawMessage).init(allocator),
        .debug = debug,
    };
}

pub fn deinit(connection: *Connection) void {
    const table = .{
        connection.responses.items,
        connection.debug_handled_responses.items,
        connection.events.items,
        connection.debug_handled_events.items,
    };

    inline for (table) |entry| {
        for (entry) |*item| {
            item.deinit();
        }
    }

    for (connection.queued_requests.items) |*request| {
        request.arena.deinit();
    }
    connection.queued_requests.deinit();

    connection.expected_responses.deinit();
    connection.handled_responses.deinit();
    connection.handled_events.deinit();
    connection.responses.deinit();
    connection.debug_handled_responses.deinit();
    connection.events.deinit();
    connection.debug_handled_events.deinit();

    connection.arena.deinit();
}

pub fn queue_request(connection: *Connection, comptime command: Command, arguments: ?protocol.Value, depends_on: Dependency) !i32 {
    try connection.queued_requests.ensureUnusedCapacity(1);
    try connection.expected_responses.ensureUnusedCapacity(1);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    const request = protocol.Request{
        .seq = connection.new_seq(),
        .type = .request,
        .command = @tagName(command),
        .arguments = arguments,
    };

    connection.queued_requests.appendAssumeCapacity(.{
        .arena = arena,
        .object = try utils.value_to_object(arena.allocator(), request),
        .seq = request.seq,
        .command = command,
        .depends_on = depends_on,
    });

    connection.expected_responses.appendAssumeCapacity(.{
        .request_seq = request.seq,
        .command = command,
        .success = false, // unknown for now
    });

    return request.seq;
}

pub fn send_request(connection: *Connection, request: Request) !void {
    switch (connection.state) {
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
        .not_spawned => return error.AdapterNotSpawned,
        .initialized, .spawned, .attached, .launched => {},
    }

    try connection.check_request_capability(request.command);
    const message = try io.create_message(connection.allocator, request.object);
    defer connection.allocator.free(message);
    try connection.adapter_write_all(message);
    request.arena.deinit();
}

pub fn handled_event(connection: *Connection, event: Event, seq: i32) void {
    _, const index = connection.get_event(seq) catch @panic("Only call this if you got an event");
    const raw_event = connection.events.orderedRemove(index);
    connection.handled_events.appendAssumeCapacity(event);
    if (connection.debug) {
        connection.debug_handled_events.appendAssumeCapacity(raw_event);
    } else {
        raw_event.deinit();
    }
}

pub fn handled_response(connection: *Connection, command: Command, request_seq: i32, success: bool) void {
    _, const index = connection.get_response_by_request_seq(request_seq) catch @panic("Only call this if you got a response");
    const raw_resp = connection.responses.orderedRemove(index);
    connection.handled_responses.appendAssumeCapacity(.{
        .request_seq = request_seq,
        .command = command,
        .success = success,
    });
    if (connection.debug) {
        connection.debug_handled_responses.appendAssumeCapacity(raw_resp);
    } else {
        raw_resp.deinit();
    }
}

pub fn end_session(connection: *Connection, how: enum { terminate, disconnect }) !void {
    switch (connection.state) {
        .initialized,
        .partially_initialized,
        .initializing,
        .spawned,
        => return error.SessionNotStarted,

        .not_spawned => return error.AdapterNotSpawned,

        .attached => @panic("TODO"),
        .launched => {
            switch (how) {
                .terminate => _ = try connection.queue_request_terminate(.{
                    .restart = false,
                }, .none),
                .disconnect => _ = try connection.queue_request_disconnect(.{
                    .restart = false,
                    .terminateDebuggee = null,
                    .suspendDebuggee = null,
                }, .none),
            }
        },
    }
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn queue_request_init(connection: *Connection, arguments: protocol.InitializeRequestArguments, depends_on: Dependency) !i32 {
    if (connection.state.fully_initialized()) {
        return error.AdapterAlreadyInitalized;
    }

    connection.client_capabilities = utils.bit_set_from_struct(arguments, ClientCapabilitiesSet, ClientCapabilitiesKind);

    const args = try utils.value_to_object(connection.arena.allocator(), arguments);
    const seq = try connection.queue_request(.initialize, .{ .object = args }, depends_on);
    connection.state = .initializing;
    return seq;
}

pub fn handle_response_init(connection: *Connection, request_seq: i32) !void {
    std.debug.assert(connection.state == .initializing);
    const cloner = connection.create_cloner();

    const resp = try connection.get_parse_validate_response(protocol.InitializeResponse, request_seq, .initialize);
    defer resp.deinit();
    if (resp.value.body) |body| {
        connection.adapter_capabilities.support = utils.bit_set_from_struct(body, AdapterCapabilitiesSet, AdapterCapabilitiesKind);
        connection.adapter_capabilities.completionTriggerCharacters = try utils.clone_anytype(cloner, body.completionTriggerCharacters);
        connection.adapter_capabilities.exceptionBreakpointFilters = try utils.clone_anytype(cloner, body.exceptionBreakpointFilters);
        connection.adapter_capabilities.additionalModuleColumns = try utils.clone_anytype(cloner, body.additionalModuleColumns);
        connection.adapter_capabilities.supportedChecksumAlgorithms = try utils.clone_anytype(cloner, body.supportedChecksumAlgorithms);
        connection.adapter_capabilities.breakpointModes = try utils.clone_anytype(cloner, body.breakpointModes);
    }

    connection.state = .partially_initialized;
    connection.handled_response(.initialize, request_seq, true);
}

/// extra_arguments is a key value pair to be injected into the InitializeRequest.arguments
pub fn queue_request_launch(connection: *Connection, arguments: protocol.LaunchRequestArguments, extra_arguments: protocol.Object, depends_on: Dependency) !i32 {
    var args = try utils.value_to_object(connection.arena.allocator(), arguments);
    try utils.object_merge(connection.arena.allocator(), &args, extra_arguments);
    return try connection.queue_request(.launch, .{ .object = args }, depends_on);
}

pub fn handle_response_launch(connection: *Connection, request_seq: i32) !void {
    const resp = try connection.get_parse_validate_response(protocol.LaunchResponse, request_seq, .launch);
    defer resp.deinit();
    connection.state = .launched;
    connection.handled_response(.launch, request_seq, true);
}

pub fn queue_request_configuration_done(connection: *Connection, arguments: ?protocol.ConfigurationDoneArguments, extra_arguments: protocol.Object, depends_on: Dependency) !i32 {
    var args = try utils.value_to_object(connection.arena.allocator(), arguments);
    try utils.object_merge(connection.arena.allocator(), &args, extra_arguments);
    return try connection.queue_request(.configurationDone, .{ .object = args }, depends_on);
}

pub fn handle_response_configuration_done(connection: *Connection, request_seq: i32) !void {
    const resp = try connection.get_parse_validate_response(protocol.ConfigurationDoneResponse, request_seq, .configurationDone);
    defer resp.deinit();
    connection.handled_response(.configurationDone, request_seq, true);
}

fn queue_request_terminate(connection: *Connection, arguments: ?protocol.TerminateArguments, depends_on: Dependency) !i32 {
    const args = try utils.value_to_object(connection.arena.allocator(), arguments);
    return try connection.queue_request(.terminate, .{ .object = args }, depends_on);
}

fn queue_request_disconnect(connection: *Connection, arguments: ?protocol.DisconnectArguments, depends_on: Dependency) !i32 {
    const args = try utils.value_to_object(connection.arena.allocator(), arguments);
    return try connection.queue_request(.disconnect, .{ .object = args }, depends_on);
}

pub fn handle_response_disconnect(connection: *Connection, request_seq: i32) !void {
    const resp = try connection.get_and_parse_response(protocol.DisconnectResponse, request_seq);
    defer resp.deinit();
    try validate_response(resp.value, request_seq, .disconnect);

    if (resp.value.success) {
        connection.state = .initialized;
    }

    connection.handled_response(.disconnect, request_seq, true);
}

pub fn handle_event_initialized(connection: *Connection, seq: i32) void {
    connection.state = .initialized;
    connection.handled_event(.initialized, seq);
}

pub fn queue_request_threads(connection: *Connection, arguments: ?protocol.Value, depends_on: Dependency) !i32 {
    const args = try utils.value_to_object(connection.arena.allocator(), arguments);
    return try connection.queue_request(.threads, .{ .object = args }, depends_on);
}

fn check_request_capability(connection: *Connection, command: Command) !void {
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

pub fn adapter_spawn(connection: *Connection) !void {
    if (connection.state != .not_spawned) {
        return error.AdapterAlreadySpawned;
    }
    try connection.adapter.spawn();
    connection.state = .spawned;
}

pub fn adapter_wait(connection: *Connection) !std.process.Child.Term {
    std.debug.assert(connection.state != .not_spawned);
    const code = try connection.adapter.wait();
    connection.state = .not_spawned;
    return code;
}

pub fn adapter_kill(connection: *Connection) !std.process.Child.Term {
    std.debug.assert(connection.state != .not_spawned);
    const code = try connection.adapter.kill();
    connection.state = .not_spawned;
    return code;
}

pub fn adapter_write_all(connection: *Connection, message: []const u8) !void {
    std.debug.assert(connection.state != .not_spawned);
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
        try connection.debug_handled_responses.ensureTotalCapacity(connection.handled_responses.capacity);

        try connection.events.ensureUnusedCapacity(1);
        try connection.handled_events.ensureTotalCapacity(connection.total_events_received + 1);
        try connection.debug_handled_events.ensureTotalCapacity(connection.handled_events.capacity);

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

pub fn get_response_by_request_seq(connection: *Connection, request_seq: i32) !struct { RawMessage, usize } {
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

fn value_to_object_then_write(connection: *Connection, value: anytype) !void {
    try connection.value_to_object_then_inject_then_write(value, &.{}, .{});
}

fn value_to_object_then_inject_then_write(connection: *Connection, value: anytype, ancestors: []const []const u8, extra: protocol.Object) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // value to object
    var object = try utils.value_to_object(arena.allocator(), value);
    // inject
    if (extra.map.count() > 0) {
        var ancestor = try utils.object_ancestor_get(&object, ancestors);
        var iter = extra.map.iterator();
        while (iter.next()) |entry| {
            try ancestor.map.put(arena.allocator(), entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    // write
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

pub fn wait_for_event(connection: *Connection, name: []const u8) !i32 {
    while (true) {
        try connection.queue_messages(std.time.ms_per_s);
        for (connection.events.items) |item| {
            const value_event = item.value.object.get("event").?;
            const event = switch (value_event) {
                .string => |string| string,
                else => unreachable, // this shouldn't run unless the message is invalid
            };
            if (std.mem.eql(u8, name, event)) {
                const seq = utils.get_value(item.value, "seq", .integer) orelse continue;
                return @truncate(seq);
            }
        }
    }

    unreachable;
}

pub fn get_and_parse_response(connection: *Connection, comptime T: type, seq: i32) !std.json.Parsed(T) {
    const raw_resp, _ = try connection.get_response_by_request_seq(seq);
    return try std.json.parseFromValue(T, connection.allocator, raw_resp.value, .{ .ignore_unknown_fields = true });
}

pub fn get_parse_validate_response(connection: *Connection, comptime T: type, request_seq: i32, command: Command) !std.json.Parsed(T) {
    const raw_resp, _ = try connection.get_response_by_request_seq(request_seq);
    const resp = try std.json.parseFromValue(T, connection.allocator, raw_resp.value, .{ .ignore_unknown_fields = true });
    try validate_response(resp.value, request_seq, command);

    return resp;
}

pub fn get_and_parse_event(connection: *Connection, comptime T: type, event: Event) !std.json.Parsed(T) {
    const raw_event, _ = try connection.get_event(@tagName(event));
    // this clones everything in the raw_event
    return try std.json.parseFromValue(T, connection.allocator, raw_event.value, .{});
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
