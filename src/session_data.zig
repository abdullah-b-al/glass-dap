const std = @import("std");
const protocol = @import("protocol.zig");
const Connection = @import("connection.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");
const log = std.log.scoped(.session_data);
const mem = std.mem;
const MemObject = utils.MemObject;

pub const SessionData = @This();

allocator: mem.Allocator,

/// This arena is used to store protocol.Object, protocol.Array and slices that are not a string.
arena: std.heap.ArenaAllocator,

string_storage: StringStorageUnmanaged,
threads: Threads,
modules: std.ArrayHashMapUnmanaged(ModuleID, MemObject(protocol.Module), ModuleHash, false),
breakpoints: std.ArrayListUnmanaged(MemObject(Breakpoint)),
sources: std.ArrayHashMapUnmanaged(SourceID, MemObject(protocol.Source), SourceIDHash, false),
sources_content: std.ArrayHashMapUnmanaged(SourceID, SourceContent, SourceIDHash, false),

// Output needs to be available for the whole session so MemObject isn't needed.
output: std.ArrayListUnmanaged(Output),
output_arena: std.heap.ArenaAllocator,

data_breakpoints_info: std.ArrayHashMapUnmanaged(DataBreakpointInfo.ID, MemObject(DataBreakpointInfo), DataBreakpointInfo.IDHash, false),

/// Setting of function breakpoints replaces all existing function breakpoints with new function breakpoints.
/// These are here to allow adding and removing individual breakpoints.
// These are cheap to store so for now don't use a MemObject
function_breakpoints: std.ArrayListUnmanaged(protocol.FunctionBreakpoint),
source_breakpoints: std.ArrayHashMapUnmanaged(SourceID, SourceBreakpoints, SourceIDHash, false),
data_breakpoints: std.ArrayHashMapUnmanaged(protocol.DataBreakpoint, void, DataBreakpointHash, false),

all_threads_status: enum {
    stopped,
    continued,
    null,

    pub fn to_thread_status(s: @This()) ?Thread.Status {
        return switch (s) {
            .stopped => .{ .stopped = null },
            .continued => .continued,
            .null => null,
        };
    }
},
status: DebuggeeStatus,
exit_code: ?i32,

/// From the protocol:
/// Arbitrary data from the previous, restarted connection.
/// The data is sent as the `restart` attribute of the `terminated` event.
/// The client should leave the data intact.
terminated_restart_data: ?protocol.Value = null,

pub fn init(allocator: mem.Allocator) SessionData {
    return .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .output_arena = std.heap.ArenaAllocator.init(allocator),
        .status = .not_running,
        .all_threads_status = .null,
        .exit_code = null,

        .string_storage = .empty,
        .threads = .empty,
        .modules = .empty,
        .breakpoints = .empty,
        .sources = .empty,
        .sources_content = .empty,
        .output = .empty,
        .function_breakpoints = .empty,
        .source_breakpoints = .empty,
        .data_breakpoints = .empty,
        .data_breakpoints_info = .empty,
    };
}

pub fn free(data: *SessionData, reason: enum { deinit, begin_session }) void {

    // Free elements of data structures

    {
        var iter = data.threads.iterator();
        while (iter.next()) |entry| {
            const thread = entry.value_ptr;
            thread.deinit(data.allocator);
        }
    }

    for (data.sources_content.values()) |content| {
        // content.mime_type is interned
        data.allocator.free(content.content);
    }

    for (data.source_breakpoints.values()) |*list| {
        list.deinit(data.allocator);
    }

    const mem_objects = .{
        data.modules.values(),
        data.breakpoints.items,
        data.sources.values(),
        data.data_breakpoints_info.values(),
    };
    inline for (mem_objects) |slice| {
        for (slice) |*mo| {
            mo.deinit();
        }
    }

    // Free data structures

    const to_free = .{
        &data.threads,
        &data.output,
        &data.sources_content,
        &data.function_breakpoints,
        &data.source_breakpoints,
        &data.data_breakpoints,
        &data.data_breakpoints_info,
        &data.modules,
        &data.breakpoints,
        &data.sources,
    };

    inline for (to_free) |ptr| {
        switch (reason) {
            .deinit => ptr.deinit(data.allocator),
            .begin_session => ptr.clearAndFree(data.allocator),
        }
    }

    data.string_storage.deinit(data.allocator);
    data.string_storage = .empty;

    switch (reason) {
        .deinit => {
            data.arena.deinit();
            data.output_arena.deinit();
        },
        .begin_session => {
            _ = data.arena.reset(.free_all);
            _ = data.output_arena.reset(.free_all);
        },
    }

    data.* = .{
        .status = .not_running,
        .all_threads_status = .null,

        // keep
        .exit_code = data.exit_code,
        .allocator = data.allocator,
        .arena = data.arena,
        .output_arena = data.output_arena,
        .string_storage = data.string_storage,
        .threads = data.threads,
        .modules = data.modules,
        .breakpoints = data.breakpoints,
        .sources = data.sources,
        .sources_content = data.sources_content,
        .output = data.output,
        .function_breakpoints = data.function_breakpoints,
        .data_breakpoints = data.data_breakpoints,
        .source_breakpoints = data.source_breakpoints,
        .data_breakpoints_info = data.data_breakpoints_info,
    };
}

pub fn deinit(data: *SessionData) void {
    data.free(.deinit);
}

pub fn begin_session(data: *SessionData) void {
    data.free(.begin_session);
}

pub fn end_session(data: *SessionData, restart_data: ?protocol.Value) !void {
    data.free(.end_session);
    if (restart_data) |d| {
        data.terminated_restart_data = try data.clone_anytype(d);
    }
}

pub fn thread_clear_data(data: *SessionData, thread_id: ThreadID) void {
    var thread = data.threads.getPtr(thread_id) orelse return;
    data.clear_dead_data_breakpoint_info(thread.id);
    thread.clear_all();
}

pub fn set_stopped(data: *SessionData, event: protocol.StoppedEvent) !void {
    const stopped = try utils.mem_object(data.allocator, event.body);

    if (stopped.value.threadId) |id| {
        try data.add_or_update_thread(@enumFromInt(id), null, .{ .stopped = stopped });
    }

    if (stopped.value.allThreadsStopped == null) {
        data.all_threads_status = .null;
    }

    if (stopped.value.allThreadsStopped orelse false) {
        data.all_threads_status = .stopped;
        var iter = data.threads.iterator();
        while (iter.next()) |entry| {
            const thread = entry.value_ptr;
            switch (thread.status) {
                .stopped => {},
                .unknown, .continued => thread.status = .{ .stopped = null },
            }
        }
    }
}

pub fn set_continued_event(data: *SessionData, event: protocol.ContinuedEvent) !void {
    try data.add_or_update_thread(@enumFromInt(event.body.threadId), null, .continued);

    if (event.body.allThreadsContinued != null) {
        data.all_threads_status = .null;
    }

    if (event.body.allThreadsContinued orelse true) {
        data.set_continued_all();
    }
}

pub fn set_continued_response(data: *SessionData, response: protocol.ContinueResponse) void {
    if (response.body.allThreadsContinued == null) {
        data.all_threads_status = .null;
    }

    if (response.body.allThreadsContinued orelse true) {
        data.set_continued_all();
    }
}

fn set_continued_all(data: *SessionData) void {
    data.all_threads_status = .continued;
    for (data.threads.values()) |*thread| {
        switch (thread.status) {
            .continued => {},
            .stopped => {
                thread.status.deinit();
                thread.status = .continued;
                data.thread_clear_data(thread.id);
            },
            .unknown => {
                thread.status = .continued;
                data.thread_clear_data(thread.id);
            },
        }

        thread.status = .continued;
    }
}

pub fn set_existed(data: *SessionData, event: protocol.ExitedEvent) !void {
    data.exit_code = event.body.exitCode;
}

pub fn set_output(data: *SessionData, event: protocol.OutputEvent) !void {
    try data.output.ensureUnusedCapacity(data.allocator, 1);
    const output = try data.clone_output(event.body);
    data.output.appendAssumeCapacity(output);
}

pub fn set_module(data: *SessionData, module: protocol.Module) !void {
    try data.modules.ensureUnusedCapacity(data.allocator, 1);
    const mo = try utils.mem_object(data.allocator, module);

    const gop = data.modules.getOrPut(data.allocator, module.id) catch |err| utils.oom(err);

    if (gop.found_existing) {
        gop.value_ptr.deinit();
    }

    gop.key_ptr.* = mo.value.id;
    gop.value_ptr.* = mo;
}

pub fn remove_module(data: *SessionData, module: protocol.Module) void {
    if (data.modules.getPtr(module.id)) |ptr| {
        ptr.deinit();
    }
    _ = data.modules.orderedRemove(module.id);
}

pub fn set_terminated(data: *SessionData, _: protocol.TerminatedEvent) !void {
    // const restart_data = if (event.body) |body|
    //     body.restart
    // else
    //     null;

    // TODO: Handle restart data
    data.status = .terminated;
}

pub const ThreadEventReason = blk: {
    const Body = utils.get_field_type(protocol.ThreadEvent, "body");
    break :blk utils.get_field_type(Body, "reason");
};
pub fn set_thread_from_event(data: *SessionData, id: ThreadID, reason: ThreadEventReason) !void {
    switch (reason) {
        .started => try data.add_or_update_thread(id, null, null),
        .exited => data.remove_thread(id),
        .string => |string| {
            log.info("Thread Event with unknown reason: {s}", .{string});
        },
    }
}

pub fn set_threads(data: *SessionData, threads: []const protocol.Thread) !void {
    // Remove threads that no longer exist
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const old = entry.key_ptr.*;
        if (!utils.entry_exists(threads, "id", @as(ID, @intFromEnum(old)))) {
            data.remove_thread(old);

            iter = data.threads.iterator(); // iterator invalidated
        }
    }

    for (threads) |new| {
        try data.add_or_update_thread(@enumFromInt(new.id), new.name, null);
    }
}

fn remove_thread(data: *SessionData, id: ThreadID) void {
    var thread = data.threads.getPtr(id) orelse return;
    thread.deinit(data.allocator);
    _ = data.threads.orderedRemove(id);
}

fn add_or_update_thread(data: *SessionData, id: ThreadID, name: ?[]const u8, cloned_status: ?Thread.Status) !void {
    const gop = try data.threads.getOrPut(data.allocator, id);
    var thread = gop.value_ptr;
    if (gop.found_existing) {
        if (cloned_status) |new_status| {
            thread.status.deinit();
            thread.status = new_status;
        }

        thread.* = .{
            .id = id,
            .name = if (name) |n| try data.intern_string(n) else thread.name,
            .status = thread.status,
            .requested_stack = thread.requested_stack,
            .stack = thread.stack,
            .scopes = thread.scopes,
            .variables = thread.variables,

            .selected = if (thread.status == .continued) true else thread.selected,
        };
    } else {
        gop.value_ptr.* = .{
            .id = id,
            .name = try data.intern_string(name orelse ""),
            .status = cloned_status orelse data.all_threads_status.to_thread_status() orelse .unknown,
            .selected = !(cloned_status == null or cloned_status.? == .unknown),
            .requested_stack = false,
            .stack = .empty,
            .scopes = .empty,
            .variables = .empty,
        };
    }

    if (thread.status == .continued) {
        data.thread_clear_data(thread.id);
    }
}

pub fn set_stack(data: *SessionData, thread_id: ThreadID, clear: bool, response: []const protocol.StackFrame) !void {
    const thread = data.threads.getPtr(thread_id) orelse return;

    if (clear) {
        data.thread_clear_data(thread.id);
    }

    try thread.stack.ensureUnusedCapacity(data.allocator, response.len);

    for (response) |frame| {
        thread.stack.appendAssumeCapacity(try utils.mem_object(data.allocator, frame));
        if (frame.source) |source| {
            try data.set_source(source);
        }
    }

    thread.requested_stack = true;
}

pub fn set_source(data: *SessionData, source: protocol.Source) !void {
    const id = try data.intern_source_id(
        SourceID.from_source(source) orelse return error.SourceWithoutID,
    );

    try data.sources.ensureUnusedCapacity(data.allocator, 1);
    var cloned = try utils.mem_object(data.allocator, source);
    errdefer cloned.deinit();
    const gop = data.sources.getOrPutAssumeCapacity(id);
    if (gop.found_existing) {
        gop.value_ptr.deinit();
    }
    gop.value_ptr.* = cloned;
}

pub fn get_source(data: SessionData, source_id: SourceID) ?protocol.Source {
    const maybe = switch (source_id) {
        .path => |path| data.sources.get(.{ .path = path }),
        .reference => |ref| data.sources.get(.{ .reference = ref }),
    };

    return (maybe orelse return null).value;
}

pub fn set_source_content(data: *SessionData, not_owned_key: SourceID, content: SourceContent) !void {
    try data.sources_content.ensureUnusedCapacity(data.allocator, 1);
    const key = try data.intern_source_id(not_owned_key);

    const mime_type = if (content.mime_type) |mt| try data.intern_string(mt) else null;
    const content_string = try data.allocator.dupe(u8, content.content);

    const gop = data.sources_content.getOrPutAssumeCapacity(key);

    if (gop.found_existing) {
        data.allocator.free(gop.value_ptr.content);
    }
    gop.value_ptr.* = .{
        .mime_type = mime_type,
        .content = content_string,
    };
}

pub fn set_scopes(data: *SessionData, thread_id: ThreadID, frame_id: FrameID, response: []protocol.Scope) !void {
    const thread = data.threads.getPtr(thread_id) orelse return;
    try thread.scopes.ensureUnusedCapacity(data.allocator, 1);
    const mo = try utils.mem_object(data.allocator, response);
    const gop = thread.scopes.getOrPutAssumeCapacity(frame_id);
    if (gop.found_existing) {
        for (gop.value_ptr.value) |scope| {
            data.remove_variable(thread_id, @enumFromInt(scope.variablesReference));
        }
        gop.value_ptr.deinit();
    }
    gop.value_ptr.* = mo;
}

pub fn set_variables(data: *SessionData, thread_id: ThreadID, variables_reference: VariableReference, response: []protocol.Variable) !void {
    const thread = data.threads.getPtr(thread_id) orelse return;
    try thread.variables.ensureUnusedCapacity(data.allocator, 1);
    const cloned = try utils.mem_object(data.allocator, response);
    const gop = thread.variables.getOrPutAssumeCapacity(variables_reference);
    if (gop.found_existing) {
        gop.value_ptr.deinit();
    }

    const ctx = struct {
        pub fn less_than(_: void, lhs: protocol.Variable, rhs: protocol.Variable) bool {
            return lhs.variablesReference < rhs.variablesReference;
        }
    };
    // This will sort the variables from non-structured to structured.
    mem.sort(protocol.Variable, cloned.value, {}, ctx.less_than);
    gop.value_ptr.* = cloned;
}

pub fn set_variable_value(data: *SessionData, thread_id: ThreadID, reference: VariableReference, name: []const u8, response: protocol.SetVariableResponse) !void {
    const body = response.body;
    const thread = data.threads.getPtr(thread_id) orelse return;
    const mo: MemObject([]protocol.Variable) = thread.variables.get(reference) orelse return;
    const value = try mo.strings.get_and_put(body.value);
    for (mo.value) |*variable| {
        if (std.mem.eql(u8, variable.name, name)) {
            variable.value = value;
            break;
        }
    }
}

pub fn set_variable_expression(data: *SessionData, thread_id: ThreadID, reference: VariableReference, name: []const u8, response: protocol.SetExpressionResponse) !void {
    const body = response.body;
    const thread = data.threads.getPtr(thread_id) orelse return;
    const mo: MemObject([]protocol.Variable) = thread.variables.get(reference) orelse return;
    const value = try mo.strings.get_and_put(body.value);
    for (mo.value) |*variable| {
        if (std.mem.eql(u8, variable.name, name)) {
            variable.value = value;
            break;
        }
    }
}

pub fn remove_variable(data: *SessionData, thread_id: ThreadID, reference: VariableReference) void {
    const thread = data.threads.getPtr(thread_id) orelse return;
    var entry = thread.variables.fetchOrderedRemove(reference) orelse return;
    entry.value.deinit();
}

pub fn set_breakpoints(data: *SessionData, origin: BreakpointOrigin, breakpoints: []const protocol.Breakpoint) !void {
    if (origin != .event) {
        data.clear_breakpoints(origin);
    }

    if (origin == .source) {
        try data.update_source_breakpoints_line(origin.source, breakpoints);
    }

    for (breakpoints) |bp| {
        if (origin == .event) {
            try data.update_breakpoint(bp);
        } else {
            try data.breakpoints.ensureUnusedCapacity(data.allocator, 1);
            const cloned = try utils.mem_object(data.allocator, Breakpoint{
                .origin = origin,
                .breakpoint = bp,
            });
            data.breakpoints.appendAssumeCapacity(cloned);
        }
    }
}

pub fn clear_breakpoints(data: *SessionData, origin: BreakpointOrigin) void {
    var i: usize = 0;
    while (i < data.breakpoints.items.len) {
        const entry = data.breakpoints.items[i];
        if (std.meta.activeTag(entry.value.origin) == std.meta.activeTag(origin)) {
            var value = data.breakpoints.orderedRemove(i);
            value.deinit();
        } else {
            i += 1;
        }
    }
}

pub fn remove_breakpoint(data: *SessionData, id: ?i32) void {
    const index = data.breakpoint_index(id) orelse return;
    var value = data.breakpoints.orderedRemove(index);
    value.deinit();
}

fn update_breakpoint(data: *SessionData, breakpoint: protocol.Breakpoint) !void {
    const id = breakpoint.id orelse return error.NoBreakpointIDGiven;
    const index = data.breakpoint_index(id) orelse return error.BreakpointDoesNotExist;

    var old = data.breakpoints.items[index];
    const cloned = try utils.mem_object(data.allocator, Breakpoint{
        .origin = old.value.origin,
        .breakpoint = breakpoint,
    });

    old.deinit();
    data.breakpoints.items[index] = cloned;
}

pub fn add_data_breakpoint_info(data: *SessionData, name: []const u8, thread_id: ThreadID, reference: ?VariableReference, frame_id: ?FrameID, info: DataBreakpointInfo.Body) !void {
    try data.data_breakpoints_info.ensureUnusedCapacity(data.allocator, 1);

    var clone = try utils.mem_object_undefined(data.allocator, DataBreakpointInfo);
    errdefer clone.deinit();

    const data_clone = try utils.mem_object_clone(&clone, info);
    const key_clone: DataBreakpointInfo.ID = blk: {
        const key: DataBreakpointInfo.ID =
            if (reference) |ref|
            .{ .variable = .{ .reference = ref, .name = name } }
        else if (frame_id) |frame|
            .{ .frame_expression = .{ .frame = frame, .name = name } }
        else
            .{ .global_expression = name };

        break :blk try utils.mem_object_clone(&clone, key);
    };

    clone.value = .{
        .data = data_clone,
        .lifetime = switch (key_clone) {
            .frame_expression, .variable => .{ .while_thread_suspended = thread_id },
            .global_expression => .indefinite,
        },
    };

    const gop = data.data_breakpoints_info.getOrPutAssumeCapacity(key_clone);
    if (gop.found_existing) {
        gop.value_ptr.deinit();
    }
    gop.key_ptr.* = key_clone;
    gop.value_ptr.* = clone;
}

fn clear_dead_data_breakpoint_info(data: *SessionData, continued_thread: ThreadID) void {
    var iter = data.data_breakpoints_info.iterator();
    while (iter.next()) |entry| {
        switch (entry.value_ptr.value.lifetime) {
            .while_thread_suspended => |thread_id| {
                if (thread_id == continued_thread) {
                    var kv = data.data_breakpoints_info.fetchOrderedRemove(entry.key_ptr.*).?;
                    kv.value.deinit();
                    iter = data.data_breakpoints_info.iterator();
                }
            },
            .indefinite => {},
        }
    }
}

pub fn add_data_breakpoint(data: *SessionData, breakpoint: protocol.DataBreakpoint) !bool {
    if (data.data_breakpoints.contains(breakpoint)) return false;

    try data.data_breakpoints.ensureUnusedCapacity(data.allocator, 1);
    const clone = try data.clone_anytype(breakpoint);
    data.data_breakpoints.putAssumeCapacity(clone, {});

    return true;
}

pub fn remove_data_breakpoints_of_id(data: *SessionData, data_id: []const u8) bool {
    var result = false;
    var iter = data.data_breakpoints.iterator();
    while (iter.next()) |entry| {
        if (mem.eql(u8, entry.key_ptr.dataId, data_id)) {
            _ = data.data_breakpoints.orderedRemove(entry.key_ptr.*);
            iter = data.data_breakpoints.iterator();
            result = true;
        }
    }

    return result;
}
pub fn remove_data_breakpoint(data: *SessionData, breakpoint: protocol.DataBreakpoint) bool {
    return data.data_breakpoints.orderedRemove(breakpoint);
}

pub fn add_source_breakpoint(data: *SessionData, not_owned_source_id: SourceID, breakpoint: protocol.SourceBreakpoint) !void {
    try data.source_breakpoints.ensureUnusedCapacity(data.allocator, 1);

    const source_id = try data.intern_source_id(not_owned_source_id);
    const gop = data.source_breakpoints.getOrPutAssumeCapacity(source_id);

    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }

    if (!gop.value_ptr.contains(breakpoint.line)) {
        const cloned = try data.clone_anytype(breakpoint);
        try gop.value_ptr.put(data.allocator, breakpoint.line, cloned);
    }
}

pub fn remove_source_breakpoint(data: *SessionData, source_id: SourceID, line: i32) void {
    var breakpoints = data.source_breakpoints.getPtr(source_id) orelse return;
    _ = breakpoints.swapRemove(line);
}

fn update_source_breakpoints_line(data: *SessionData, source_id: SourceID, new_breakpoints: []const protocol.Breakpoint) !void {
    const breakpoints = data.source_breakpoints.getPtr(source_id) orelse return;

    // https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetBreakpoints
    if (new_breakpoints.len != breakpoints.count()) return error.InvalidBreakpointResponse;
    for (breakpoints.keys(), breakpoints.values(), new_breakpoints) |*key, *a, b| {
        key.* = b.line orelse continue;
        a.line = b.line orelse continue;
    }

    breakpoints.reIndex(data.allocator) catch |err| switch (err) {
        error.OutOfMemory => unreachable,
    };
}

pub fn add_function_breakpoint(data: *SessionData, breakpoint: protocol.FunctionBreakpoint) !void {
    if (!utils.entry_exists(data.function_breakpoints.items, "name", breakpoint.name)) {
        try data.function_breakpoints.append(data.allocator, try data.clone_anytype(breakpoint));
    }
}

pub fn remove_function_breakpoint(data: *SessionData, name: []const u8) void {
    const index = utils.get_entry_index(data.function_breakpoints.items, "name", name) orelse return;
    _ = data.function_breakpoints.orderedRemove(index);
}

fn breakpoint_index(data: SessionData, maybe_id: ?i32) ?usize {
    const id = maybe_id orelse return null;
    for (data.breakpoints.items, 0..) |item, i| {
        if (item.value.breakpoint.id == id) {
            return i;
        }
    }

    return null;
}

fn clone_output(data: *SessionData, value: anytype) error{OutOfMemory}!@TypeOf(value) {
    const Cloner = struct {
        const Cloner = @This();
        data: *SessionData,
        allocator: mem.Allocator,
    };

    const cloner = Cloner{
        .data = data,
        .allocator = data.output_arena.allocator(),
    };
    return try utils.clone_anytype(cloner, value);
}

fn clone_anytype(data: *SessionData, value: anytype) error{OutOfMemory}!@TypeOf(value) {
    const Cloner = struct {
        const Cloner = @This();
        data: *SessionData,
        allocator: mem.Allocator,
        pub fn clone_string(cloner: Cloner, string: []const u8) ![]const u8 {
            return try cloner.data.intern_string(string);
        }
    };

    const cloner = Cloner{
        .data = data,
        .allocator = data.arena.allocator(),
    };
    return try utils.clone_anytype(cloner, value);
}

fn intern_string(data: *SessionData, string: []const u8) ![]const u8 {
    return try data.string_storage.get_and_put(data.allocator, string);
}

fn intern_source_id(data: *SessionData, source_id: SourceID) !SourceID {
    return switch (source_id) {
        .path => |path| .{ .path = try data.string_storage.get_and_put(data.allocator, path) },
        .reference => |ref| .{ .reference = ref },
    };
}

const DebuggeeStatus = union(enum) {
    not_running,
    running,
    stopped,
    terminated,
};

pub const ID = i32;
pub const ThreadID = enum(ID) { _ };
pub const FrameID = enum(ID) { _ };
pub const ScopeID = enum(ID) { _ };
pub const VariableReference = enum(ID) { _ };

pub const Threads = std.AutoArrayHashMapUnmanaged(ThreadID, Thread);
pub const Thread = struct {
    const Status = union(enum) {
        stopped: ?MemObject(Stopped),
        continued,
        unknown,

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .stopped => |stopped| if (stopped) |_| self.stopped.?.deinit(),
                else => {},
            }
        }
    };

    id: ThreadID,
    name: []const u8,
    status: Status,
    selected: bool,

    requested_stack: bool,
    stack: std.ArrayListUnmanaged(MemObject(protocol.StackFrame)),
    scopes: std.AutoArrayHashMapUnmanaged(FrameID, MemObject([]protocol.Scope)),
    variables: std.AutoArrayHashMapUnmanaged(VariableReference, MemObject([]protocol.Variable)),

    pub fn deinit(thread: *Thread, allocator: mem.Allocator) void {
        thread.clear_all();

        thread.stack.deinit(allocator);
        thread.scopes.deinit(allocator);
        thread.variables.deinit(allocator);
        thread.status.deinit();
    }

    fn clear_all(thread: *Thread) void {
        thread.clear_variables();
        thread.clear_scopes();
        thread.clear_stack();
    }

    fn clear_stack(thread: *Thread) void {
        for (thread.stack.items) |*mo| {
            mo.deinit();
        }
        thread.stack.clearRetainingCapacity();
        thread.* = .{
            .requested_stack = false,

            // keep
            .id = thread.id,
            .name = thread.name,
            .status = thread.status,
            .stack = thread.stack,
            .scopes = thread.scopes,
            .variables = thread.variables,
            .selected = thread.selected,
        };
    }

    fn clear_scopes(thread: *Thread) void {
        for (thread.scopes.values()) |*mo| {
            mo.deinit();
        }
        thread.scopes.clearRetainingCapacity();
        // make sure we aren't forgetting to set a new field
        thread.* = .{
            .scopes = thread.scopes,
            .id = thread.id,
            .requested_stack = thread.requested_stack,
            .name = thread.name,
            .status = thread.status,
            .stack = thread.stack,
            .variables = thread.variables,
            .selected = thread.selected,
        };
    }

    fn clear_variables(thread: *Thread) void {
        for (thread.variables.values()) |*mo| {
            mo.deinit();
        }
        thread.variables.clearRetainingCapacity();
        // make sure we aren't forgetting to set a new field
        thread.* = .{
            .variables = thread.variables,
            .scopes = thread.scopes,
            .id = thread.id,
            .requested_stack = thread.requested_stack,
            .name = thread.name,
            .status = thread.status,
            .stack = thread.stack,
            .selected = thread.selected,
        };
    }
};

pub const SourceID = union(enum) {
    path: []const u8,
    reference: i32,

    pub fn eql(a: SourceID, b: SourceID) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .path => mem.eql(u8, a.path, b.path),
            .reference => a.reference == b.reference,
        };
    }

    pub fn from_source(source: protocol.Source) ?SourceID {
        return if (source.sourceReference) |ref|
            .{ .reference = ref }
        else if (source.path) |path|
            .{ .path = path }
        else
            null;
    }
};

pub const SourceIDHash = union(enum) {
    pub fn hash(_: @This(), key: SourceID) u32 {
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .path => |path| std.hash.autoHashStrat(&hasher, path, .Deep),
            .reference => |ref| std.hash.autoHashStrat(&hasher, ref, .Deep),
        }

        return @as(u32, @truncate(hasher.final()));
    }

    pub fn eql(_: @This(), a: SourceID, b: SourceID, _: usize) bool {
        return a.eql(b);
    }
};

pub const ModuleID = utils.get_field_type(protocol.Module, "id");
pub const ModuleHash = union(enum) {
    pub fn hash(_: @This(), key: ModuleID) u32 {
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .integer => |integer| std.hash.autoHashStrat(&hasher, integer, .Deep),
            .string => |string| std.hash.autoHashStrat(&hasher, string, .Deep),
        }

        return @as(u32, @truncate(hasher.final()));
    }

    pub fn eql(_: @This(), a: ModuleID, b: ModuleID, _: usize) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .integer => a.integer == b.integer,
            .string => mem.eql(u8, a.string, b.string),
        };
    }
};

pub const SourceContent = struct {
    content: []const u8,
    mime_type: ?[]const u8,
};

pub const BreakpointOrigin = union(enum) {
    event,
    source: SourceID,
    function,
    data,
};

pub const Breakpoint = struct {
    origin: BreakpointOrigin,
    breakpoint: protocol.Breakpoint,
};

pub const SourceBreakpoints = std.AutoArrayHashMapUnmanaged(i32, protocol.SourceBreakpoint);

pub const Stopped = utils.get_field_type(protocol.StoppedEvent, "body");
pub const Continued = utils.get_field_type(protocol.ContinuedEvent, "body");
pub const Output = utils.get_field_type(protocol.OutputEvent, "body");

pub const DataBreakpointHash = struct {
    pub fn hash(_: @This(), key: protocol.DataBreakpoint) u32 {
        var hasher = std.hash.Wyhash.init(0);

        std.hash.autoHashStrat(&hasher, key.dataId, .Deep);
        std.hash.autoHashStrat(&hasher, key.accessType, .Deep);
        std.hash.autoHashStrat(&hasher, key.condition, .Deep);
        std.hash.autoHashStrat(&hasher, key.hitCondition, .Deep);

        return @as(u32, @truncate(hasher.final()));
    }

    pub fn eql(_: @This(), a: protocol.DataBreakpoint, b: protocol.DataBreakpoint, _: usize) bool {
        if (mem.eql(u8, a.dataId, b.dataId) and
            a.accessType == b.accessType and
            mem.eql(u8, a.condition orelse "", b.condition orelse "") and
            mem.eql(u8, a.hitCondition orelse "", b.hitCondition orelse ""))
        {
            return true;
        }

        return false;
    }
};

pub const DataBreakpointInfo = struct {
    pub const Body = utils.get_field_type(protocol.DataBreakpointInfoResponse, "body");

    lifetime: union(enum) {
        while_thread_suspended: ThreadID,
        indefinite,
    },

    data: Body,

    pub fn available(self: DataBreakpointInfo) bool {
        return self.id == .string;
    }

    pub const ID = union(enum) {
        variable: struct {
            reference: VariableReference,
            name: []const u8,
        },
        frame_expression: struct {
            frame: FrameID,
            name: []const u8,
        },
        global_expression: []const u8,
    };

    pub const IDHash = union(enum) {
        pub fn hash(_: @This(), key: DataBreakpointInfo.ID) u32 {
            var hasher = std.hash.Wyhash.init(0);
            switch (key) {
                .variable => |variable| {
                    std.hash.autoHashStrat(&hasher, variable.reference, .Deep);
                    std.hash.autoHashStrat(&hasher, variable.name, .Deep);
                },
                .frame_expression => |expr| {
                    std.hash.autoHashStrat(&hasher, expr.frame, .Deep);
                    std.hash.autoHashStrat(&hasher, expr.name, .Deep);
                },
                .global_expression => |string| std.hash.autoHashStrat(&hasher, string, .Deep),
            }

            return @as(u32, @truncate(hasher.final()));
        }

        pub fn eql(_: @This(), a: DataBreakpointInfo.ID, b: DataBreakpointInfo.ID, _: usize) bool {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                .variable => {
                    return a.variable.reference == b.variable.reference and std.mem.eql(u8, a.variable.name, b.variable.name);
                },
                .frame_expression => {
                    return a.frame_expression.frame == b.frame_expression.frame and std.mem.eql(u8, a.frame_expression.name, b.frame_expression.name);
                },
                .global_expression => {
                    return std.mem.eql(u8, a.global_expression, b.global_expression);
                },
            }
        }
    };
};
