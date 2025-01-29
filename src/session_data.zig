const std = @import("std");
const protocol = @import("protocol.zig");
const Connection = @import("connection.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");
const log = std.log.scoped(.session_data);

const DebuggeeStatus = union(enum) {
    not_running,
    running,
    stopped,
    exited: i32,
};

const Thread = struct {
    data: protocol.Thread,
    state: union(enum) {
        running,
        stopped: struct {
            description: []const u8 = "",
            text: []const u8 = "",
        },
    },
};

pub const SessionData = struct {
    allocator: std.mem.Allocator,

    /// This arena is used to store protocol.Object, protocol.Array and slices that are not a string.
    arena: std.heap.ArenaAllocator,

    string_storage: StringStorageUnmanaged = .{},
    threads: std.ArrayListUnmanaged(Thread) = .{},
    modules: std.ArrayListUnmanaged(protocol.Module) = .{},
    output: std.ArrayListUnmanaged(protocol.OutputEvent) = .{},
    status: DebuggeeStatus,

    /// From the protocol:
    /// Arbitrary data from the previous, restarted connection.
    /// The data is sent as the `restart` attribute of the `terminated` event.
    /// The client should leave the data intact.
    terminated_restart_data: ?protocol.Value = null,

    pub fn init(allocator: std.mem.Allocator) SessionData {
        return .{
            .status = .not_running,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(data: *SessionData) void {
        data.string_storage.deinit(data.allocator);
        data.threads.deinit(data.allocator);
        data.modules.deinit(data.allocator);
        data.output.deinit(data.allocator);

        data.arena.deinit();
    }

    pub fn handle_event(data: *SessionData, connection: *Connection, event: Connection.Event) !void {
        switch (event) {
            .stopped => try data.handle_event_stopped(connection),
            .continued => try data.handle_event_continued(connection),
            .exited => try data.handle_event_exited(connection),
            .terminated => try data.handle_event_terminated(connection),
            .thread => log.err("TODO event: {s}", .{@tagName(event)}),
            .output => try data.handle_event_output(connection),
            .breakpoint => log.err("TODO event: {s}", .{@tagName(event)}),
            .module => try data.handle_event_modules(connection),
            .loadedSource => log.err("TODO event: {s}", .{@tagName(event)}),
            .process => log.err("TODO event: {s}", .{@tagName(event)}),
            .capabilities => log.err("TODO event: {s}", .{@tagName(event)}),
            .progressStart => log.err("TODO event: {s}", .{@tagName(event)}),
            .progressUpdate => log.err("TODO event: {s}", .{@tagName(event)}),
            .progressEnd => log.err("TODO event: {s}", .{@tagName(event)}),
            .invalidated => log.err("TODO event: {s}", .{@tagName(event)}),
            .memory => log.err("TODO event: {s}", .{@tagName(event)}),
            .initialized => {
                const parsed = try connection.get_and_parse_event(protocol.InitializedEvent, .initialized);
                defer parsed.deinit();
                connection.handle_event_initialized(parsed.value.seq);
            },
        }
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

            .threads => data.handle_response_threads(connection, request_seq),

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
            .stackTrace => log.err("TODO: {s}", .{@tagName(command)}),
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
            error.RequestFailed,
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
            error.ResponseDoesNotExist => return false,
        };

        return true;
    }

    fn handle_event_stopped(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.StoppedEvent, .stopped);
        defer event.deinit();

        const body = event.value.body;
        if (body.threadId) |id| {
            const thread = data.get_thread(id).?; // FIXME: Don't panic
            thread.state = .{ .stopped = .{
                .description = try data.get_or_clone_string(body.description orelse ""),
                .text = try data.get_or_clone_string(body.text orelse ""),
            } };
        }

        connection.handled_event(.stopped, event.value.seq);
    }

    fn handle_event_continued(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.ContinuedEvent, .continued);
        defer event.deinit();

        const all = event.value.body.allThreadsContinued orelse false;
        const id = event.value.body.threadId;
        for (data.threads.items) |*item| {
            if (item.data.id == id or all)
                item.state = .running;
        }

        data.status = .running;

        connection.handled_event(.continued, event.value.seq);
    }

    fn handle_event_exited(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.ExitedEvent, .exited);
        defer event.deinit();

        data.status = .{ .exited = event.value.body.exitCode };

        connection.handled_event(.exited, event.value.seq);
    }

    fn handle_event_output(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.OutputEvent, .output);
        defer event.deinit();
        try data.output.ensureUnusedCapacity(data.allocator, 1);
        const output = try data.clone_anytype(event.value);
        data.output.appendAssumeCapacity(output);

        connection.handled_event(.output, event.value.seq);
    }

    fn handle_event_modules(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.ModuleEvent, .module);
        defer event.deinit();
        try data.add_module(event.value.body.module);
        connection.handled_event(.module, event.value.seq);
    }

    fn handle_event_terminated(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.TerminatedEvent, .terminated);
        defer event.deinit();

        if (event.value.body) |body| {
            data.terminated_restart_data = try data.clone_anytype(body.restart);
        }

        if (data.status != .exited) {
            data.status = .not_running;
        }

        connection.handled_event(.terminated, event.value.seq);
    }

    pub fn handle_response_threads(data: *SessionData, connection: *Connection, seq: i32) !void {
        const parsed = try connection.get_parse_validate_response(protocol.ThreadsResponse, seq, .threads);
        defer parsed.deinit();
        const array = parsed.value.body.threads;
        try data.set_threads(array);

        connection.handled_response(.threads, seq, true);
    }

    pub fn add_module(data: *SessionData, module: protocol.Module) !void {
        try data.modules.ensureUnusedCapacity(data.allocator, 1);

        if (!entry_exists(data.modules.items, "id", module.id)) {
            data.modules.appendAssumeCapacity(try data.clone_anytype(module));
        }
    }

    pub fn set_threads(data: *SessionData, threads: []const protocol.Thread) !void {
        data.threads.clearRetainingCapacity();
        try data.threads.ensureUnusedCapacity(data.allocator, threads.len);
        for (threads) |thread| {
            data.threads.appendAssumeCapacity(.{
                .data = try data.clone_anytype(thread),
                .state = if (data.status == .running) .running else .{ .stopped = .{} },
            });
        }
    }

    fn clone_anytype(data: *SessionData, value: anytype) error{OutOfMemory}!@TypeOf(value) {
        const Cloner = struct {
            const Cloner = @This();
            data: *SessionData,
            allocator: std.mem.Allocator,
            pub fn clone_string(cloner: Cloner, string: []const u8) ![]const u8 {
                return try cloner.data.get_or_clone_string(string);
            }
        };

        const cloner = Cloner{
            .data = data,
            .allocator = data.arena.allocator(),
        };
        return try utils.clone_anytype(cloner, value);
    }

    fn get_or_clone_string(data: *SessionData, string: []const u8) ![]const u8 {
        return try data.string_storage.get_and_put(data.allocator, string);
    }

    fn entry_exists(slice: anytype, comptime field_name: []const u8, value: anytype) bool {
        for (slice) |item| {
            if (std.meta.eql(@field(item, field_name), value)) {
                return true;
            }
        }

        return false;
    }

    fn get_thread(data: *SessionData, id: i32) ?*Thread {
        for (data.threads.items) |*item| {
            if (item.data.id == id) {
                return item;
            }
        }
        return null;
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
};
