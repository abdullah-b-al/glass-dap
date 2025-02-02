const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const Args = @import("main.zig").Args;
const request = @import("request.zig");
const io = @import("io.zig");

pub fn init_ui(allocator: std.mem.Allocator) !*glfw.Window {
    try glfw.init();

    const gl_major = 4;
    const gl_minor = 0;
    glfw.windowHint(.context_version_major, gl_major);
    glfw.windowHint(.context_version_minor, gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);

    const window = try glfw.Window.create(1000, 1000, "TestWindow:unidep", null);
    window.setSizeLimits(400, 400, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    // opengl
    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    // imgui
    zgui.init(allocator);
    zgui.io.setConfigFlags(.{ .dock_enable = true });

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    _ = zgui.io.addFontFromFile(
        "/home/ab55al/.local/share/fonts/JetBrainsMono-Regular.ttf",
        std.math.floor(24.0 * scale_factor),
    );

    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);

    return window;
}

pub fn deinit_ui(window: *glfw.Window) void {
    zgui.backend.deinit();
    zgui.deinit();
    window.destroy();
    glfw.terminate();
}

pub fn ui_tick(window: *glfw.Window, connection: *Connection, data: *SessionData, args: Args) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const gl = zopengl.bindings;
    glfw.pollEvents();

    gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0, 0, 0, 1.0 });

    const fb_size = window.getFramebufferSize();

    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

    debug_ui(arena.allocator(), connection, data, args) catch |err| std.log.err("{}", .{err});

    zgui.backend.draw();

    window.swapBuffers();
}

fn debug_threads(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const table = .{
        .{ .name = "Actions" },
        .{ .name = "ID" },
        .{ .name = "Name" },
        .{ .name = "State" },
    };

    const columns_count = std.meta.fields(@TypeOf(table)).len;
    if (zgui.beginTable("Thread Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        inline for (table) |entry| {
            zgui.tableSetupColumn(entry.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.threads.items) |item| {
            const thread = data.get_thread_data(item.id) orelse continue;

            zgui.tableNextRow(.{});
            { // column 1
                _ = zgui.tableNextColumn();
                if (zgui.button("Get Full State", .{})) {
                    request.get_debuggee_state(connection, thread.id) catch return;
                }
                if (zgui.button("Stack Trace", .{})) {
                    const args = protocol.StackTraceArguments{
                        .threadId = thread.id,
                        .startFrame = null, // request all frames
                        .levels = null, // request all levels
                        .format = null,
                    };
                    _ = connection.queue_request(.stackTrace, args, .none, .{
                        .stack_trace = .{
                            .thread_id = thread.id,
                            .request_scopes = false,
                            .request_variables = false,
                        },
                    }) catch return;
                }

                zgui.sameLine(.{});
                if (zgui.button("Scopes", .{})) {
                    for (data.stack_frames.items) |entry| {
                        for (entry.data) |frame| {
                            _ = connection.queue_request(
                                .scopes,
                                protocol.ScopesArguments{ .frameId = frame.id },
                                .none,
                                .{ .scopes = .{ .frame_id = frame.id, .request_variables = false } },
                            ) catch return;
                        }
                    }
                }

                zgui.sameLine(.{});
                if (zgui.button("Variables", .{})) {
                    for (data.scopes.items) |entry| {
                        for (entry.data) |scope| {
                            _ = connection.queue_request(
                                .variables,
                                protocol.VariablesArguments{ .variablesReference = scope.variablesReference },
                                .none,
                                .{ .variables = .{ .variables_reference = scope.variablesReference } },
                            ) catch return;
                        }
                    }
                }

                zgui.sameLine(.{});
                if (zgui.button("Pause", .{})) {
                    _ = connection.queue_request(.pause, protocol.PauseArguments{
                        .threadId = thread.id,
                    }, .none, .no_data) catch return;
                }

                var arg = protocol.NextArguments{
                    .threadId = thread.id,
                    .singleThread = true,
                    .granularity = .line,
                };
                if (zgui.button("Next Line", .{})) {
                    arg.granularity = .line;
                    _ = connection.queue_request(.next, arg, .none, .no_data) catch return;
                }
                zgui.sameLine(.{});
                if (zgui.button("Next Statement", .{})) {
                    arg.granularity = .statement;
                    _ = connection.queue_request(.next, arg, .none, .no_data) catch return;
                }
                zgui.sameLine(.{});
                if (zgui.button("Next Instruction", .{})) {
                    arg.granularity = .instruction;
                    _ = connection.queue_request(.next, arg, .none, .no_data) catch return;
                }
            } // column 1

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.id, .{})});

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.name, .{})});

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.state, .{})});
        }

        zgui.endTable();
    }
}

fn debug_modules(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData) void {
    _ = arena;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const table = .{
        .{ .name = "ID", .field = "id" },
        .{ .name = "Name", .field = "name" },
        .{ .name = "Path", .field = "path" },
        .{ .name = "Address Range", .field = "addressRange" },
        .{ .name = "Optimized", .field = "isOptimized" },
        .{ .name = "Is User Code", .field = "isUserCode" },
        .{ .name = "Version", .field = "version" },
        .{ .name = "Symbol Status", .field = "symbolStatus" },
        .{ .name = "Symbol File Path", .field = "symbolFilePath" },
        .{ .name = "Date Timestamp", .field = "dateTimeStamp" },
    };
    const columns_count = std.meta.fields(@TypeOf(table)).len;

    if (zgui.beginTable("Modules Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        inline for (table) |entry| {
            zgui.tableSetupColumn(entry.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.modules.items) |module| {
            zgui.tableNextRow(.{});
            inline for (table) |entry| {
                _ = zgui.tableNextColumn();
                const value = @field(module, entry.field);
                zgui.text("{s}", .{anytype_to_string(value, .{
                    .value_for_null = "Unknown",
                })});
            }
        }
        zgui.endTable();
    }
}

fn debug_stack_frames(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.stack_frames.items) |item| {
        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrintZ(&buf, "Thread ID {}##variables slice", .{item.thread_id}) catch return;
        draw_table_from_slice_of_struct(n, protocol.StackFrame, item.data);
        zgui.newLine();
    }
}

fn debug_scopes(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.scopes.items) |item| {
        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrintZ(&buf, "Frame ID {}##scopes slice", .{item.frame_id}) catch return;
        draw_table_from_slice_of_struct(n, protocol.Scope, item.data);
        zgui.newLine();
    }
}

fn debug_variables(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.variables.items) |item| {
        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrintZ(&buf, "Reference {}##variables slice", .{item.reference}) catch return;
        draw_table_from_slice_of_struct(n, protocol.Variable, item.data);
        zgui.newLine();
    }
}

fn debug_breakpoints(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    draw_table_from_slice_of_struct("breakpoints", protocol.Breakpoint, data.breakpoints.items);
}

fn debug_sources(arena: std.mem.Allocator, name: [:0]const u8, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const columns_count = std.meta.fields(protocol.Source).len + 1;
    if (zgui.beginTable("Source Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        zgui.tableSetupColumn("Actions", .{});
        inline for (std.meta.fields(protocol.Source)) |field| {
            zgui.tableSetupColumn(field.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.sources.items, 0..) |source, i| {
            const button_name = std.fmt.allocPrintZ(arena, "Get Content##{}", .{i}) catch return;
            zgui.tableNextRow(.{});
            _ = zgui.tableNextColumn();
            if (zgui.button(button_name, .{})) blk: {
                if (source.path) |path| {
                    const new_source = io.open_file_as_source_content(arena, path) catch break :blk;
                    data.set_source_content(new_source) catch break :blk;
                } else {
                    _ = connection.queue_request(
                        .source,
                        protocol.SourceArguments{
                            .source = source,
                            .sourceReference = source.sourceReference.?,
                        },
                        .none,
                        .{ .source = .{ .path = source.path, .source_reference = source.sourceReference.? } },
                    ) catch return;
                }
            }

            inline for (std.meta.fields(protocol.Source)) |field| {
                _ = zgui.tableNextColumn();
                const value = @field(source, field.name);
                zgui.text("{s}", .{anytype_to_string(value, .{})});
            }
        }
        zgui.endTable();
    }
}

fn debug_sources_content(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = arena;
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    zgui.text("len {}", .{data.sources_content.items.len});
    zgui.newLine();

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Sources Content Tabs", .{})) return;

    var buf: [512:0]u8 = undefined;
    for (data.sources_content.items, 0..) |entry, i| {
        var tab_name: [:0]const u8 = undefined;
        if (entry.path) |path| {
            tab_name = std.fmt.bufPrintZ(&buf, "{s}##Sources", .{path}) catch continue;
        } else {
            tab_name = std.fmt.bufPrintZ(&buf, "{}##Sources", .{i}) catch continue;
        }

        const active_line: ?i32 = blk: {
            const frame = get_frame_of_source_content(data, entry) orelse break :blk null;
            break :blk frame.line;
        };

        var line_number: i32 = 0;
        if (zgui.beginTabItem(tab_name, .{})) {
            defer zgui.endTabItem();

            var iter = std.mem.splitScalar(u8, entry.content, '\n');
            while (iter.next()) |line| {
                const color: [4]f32 = if (active_line == line_number) .{ 1, 0, 0, 1 } else .{ 1, 1, 1, 1 };
                zgui.textColored(color, "{s}", .{line});

                line_number += 1;
            }
        }
    }
}

fn debug_ui(arena: std.mem.Allocator, connection: *Connection, data: *SessionData, args: Args) !void {
    const static = struct {
        var built_layout = false;
    };
    if (!static.built_layout) {
        static.built_layout = true;
        const dockspace_id = zgui.DockSpaceOverViewport(0, zgui.getMainViewport(), .{});

        zgui.dockBuilderRemoveNode(dockspace_id);
        const viewport = zgui.getMainViewport();
        const empty = zgui.dockBuilderAddNode(dockspace_id, .{});
        zgui.dockBuilderSetNodeSize(empty, viewport.getSize());

        // const dock_main_id: ?*zgui.Ident = &dockspace_id; // This variable will track the document node, however we are not using it here as we aren't docking anything into it.
        // const left = zgui.dockBuilderSplitNode(dock_main_id.?.*, .left, 0.50, null, dock_main_id);
        // const right = zgui.dockBuilderSplitNode(dock_main_id.?.*, .right, 0.50, null, dock_main_id);

        // dock them tabbed
        zgui.dockBuilderDockWindow("Debug General", empty);
        zgui.dockBuilderDockWindow("Debug Modules", empty);
        zgui.dockBuilderDockWindow("Debug Threads", empty);
        zgui.dockBuilderDockWindow("Debug Stack Frames", empty);
        zgui.dockBuilderDockWindow("Debug Scopes", empty);
        zgui.dockBuilderDockWindow("Debug Variables", empty);
        zgui.dockBuilderDockWindow("Debug Breakpoints", empty);
        zgui.dockBuilderDockWindow("Debug Sources", empty);
        zgui.dockBuilderDockWindow("Debug Sources Content", empty);

        zgui.dockBuilderFinish(dockspace_id);

        _ = zgui.DockSpace("Debug DockSpace", viewport.getSize(), .{});
    }

    debug_modules(arena, "Debug Modules", data.*);
    debug_threads(arena, "Debug Threads", data.*, connection);
    debug_stack_frames(arena, "Debug Stack Frames", data.*, connection);
    debug_scopes(arena, "Debug Scopes", data.*, connection);
    debug_variables(arena, "Debug Variables", data.*, connection);
    debug_breakpoints(arena, "Debug Breakpoints", data.*, connection);
    debug_sources(arena, "Debug Sources", data, connection);
    debug_sources_content(arena, "Debug Sources Content", data.*, connection);

    var open: bool = true;
    zgui.showDemoWindow(&open);

    defer zgui.end();
    if (!zgui.begin("Debug General", .{})) return;

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Debug Tabs", .{})) return;

    if (zgui.beginTabItem("Manully Send Requests", .{})) {
        defer zgui.endTabItem();
        try manual_requests(connection, data, args);
    }

    if (zgui.beginTabItem("Adapter Capabilities", .{})) {
        defer zgui.endTabItem();
        adapter_capabilities(connection.*);
    }

    if (zgui.beginTabItem("Sent Requests", .{})) {
        defer zgui.endTabItem();
        for (connection.debug_requests.items) |item| {
            var buf: [512]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "seq({}){s}", .{ item.seq, @tagName(item.command) }) catch unreachable;
            recursively_draw_protocol_object(arena, slice, slice, .{ .object = item.object });
        }
    }

    const table = .{
        .{ .name = "Queued Responses", .items = connection.responses.items },
        .{ .name = "Debug Handled Responses", .items = connection.debug_handled_responses.items },
        .{ .name = "Events", .items = connection.events.items },
        .{ .name = "Debug Handled Events", .items = connection.debug_handled_events.items },
    };
    inline for (table) |element| {
        if (zgui.beginTabItem(element.name, .{})) {
            defer zgui.endTabItem();
            for (element.items) |resp| {
                const seq = resp.value.object.get("seq").?.integer;
                var buf: [512]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "seq[{}]", .{seq}) catch unreachable;
                recursively_draw_object(arena, slice, slice, resp.value);
            }
        }
    }

    if (zgui.beginTabItem("Handled Responses", .{})) {
        defer zgui.endTabItem();
        draw_table_from_slice_of_struct(@typeName(Connection.HandledResponse), Connection.HandledResponse, connection.handled_responses.items);
    }

    if (zgui.beginTabItem("Handled Events", .{})) {
        defer zgui.endTabItem();
        for (connection.handled_events.items) |event| {
            zgui.text("{s}", .{@tagName(event)});
        }
    }

    if (zgui.beginTabItem("Console Output", .{})) {
        defer zgui.endTabItem();
        console(data.*);
    }
}

fn console(data: SessionData) void {
    for (data.output.items) |item| {
        zgui.text("{s}", .{item.body.output});
    }
}

fn adapter_capabilities(connection: Connection) void {
    if (connection.state == .not_spawned) return;

    var iter = connection.adapter_capabilities.support.iterator();
    while (iter.next()) |e| {
        const name = @tagName(e);
        var color = [4]f32{ 1, 1, 1, 1 };
        if (std.mem.endsWith(u8, name, "Request")) {
            color = .{ 0, 0, 1, 1 };
        }
        zgui.textColored(color, "{s}", .{name});
    }

    const c = connection.adapter_capabilities;
    if (c.completionTriggerCharacters) |chars| {
        for (chars) |string| {
            zgui.text("completionTriggerCharacters {s}", .{string});
        }
    } else {
        zgui.text("No completionTriggerCharacters", .{});
    }
    if (c.supportedChecksumAlgorithms) |checksum| {
        for (checksum) |kind| {
            zgui.text("supportedChecksumAlgorithms.{s}", .{@tagName(kind)});
        }
    } else {
        zgui.text("No supportedChecksumAlgorithms", .{});
    }

    draw_table_from_slice_of_struct(@typeName(protocol.ExceptionBreakpointsFilter), protocol.ExceptionBreakpointsFilter, c.exceptionBreakpointFilters);
    draw_table_from_slice_of_struct(@typeName(protocol.ColumnDescriptor), protocol.ColumnDescriptor, c.additionalModuleColumns);
    draw_table_from_slice_of_struct(@typeName(protocol.BreakpointMode), protocol.BreakpointMode, c.breakpointModes);
}

fn manual_requests(connection: *Connection, data: *SessionData, args: Args) !void {
    const static = struct {
        var name_buf: [512:0]u8 = .{0} ** 512;
        var source_buf: [512:0]u8 = .{0} ** 512;
    };

    zgui.text("Adapter State: {s}", .{@tagName(connection.state)});
    zgui.text("Debuggee Status: {s}", .{anytype_to_string(data.status, .{ .show_union_name = true })});

    if (zgui.button("Begin Debug Sequence", .{})) {
        try request.begin_session(connection, args.debugee);
    }

    zgui.sameLine(.{});
    zgui.text("or", .{});

    zgui.sameLine(.{});
    if (zgui.button("Spawn Adapter", .{})) {
        try connection.adapter_spawn();
    }

    zgui.sameLine(.{});
    if (zgui.button("Initialize Adapter", .{})) {
        const init_args = protocol.InitializeRequestArguments{
            .clientName = "unidep",
            .adapterID = "???",
            .columnsStartAt1 = false,
            .linesStartAt1 = false,
        };

        _ = try connection.queue_request_init(init_args, .none);
    }

    zgui.sameLine(.{});
    if (zgui.button("Send Launch Request", .{})) {
        var extra = protocol.Object{};
        defer extra.deinit(connection.allocator);
        try extra.map.put(connection.allocator, "program", .{ .string = args.debugee });
        _ = try connection.queue_request_launch(.{}, extra, .{ .response = .initialize });
    }

    zgui.sameLine(.{});
    if (zgui.button("Send configurationDone Request", .{})) {
        _ = try connection.queue_request_configuration_done(null, .{
            .map = .{},
        }, .{ .event = .initialized });
    }

    if (zgui.button("end connection: disconnect", .{})) {
        try request.end_session(connection, .disconnect);
    }

    if (zgui.button("end connection: terminate", .{})) {
        try request.end_session(connection, .terminate);
    }

    if (zgui.button("Threads", .{})) {
        _ = try connection.queue_request(.threads, null, .none, .no_data);
    }

    _ = zgui.inputText("source reference", .{ .buf = &static.source_buf });
    if (zgui.button("Source Content", .{})) blk: {
        const len = std.mem.indexOfScalar(u8, &static.source_buf, 0) orelse static.source_buf.len;
        const id = static.source_buf[0..len];
        const number = std.fmt.parseInt(i32, id, 10) catch break :blk;
        const source = data.get_source_by_reference(number);
        if (source) |s| {
            _ = try connection.queue_request(
                .source,
                protocol.SourceArguments{
                    .source = s,
                    .sourceReference = s.sourceReference.?,
                },
                .none,
                .{ .source = .{ .path = s.path, .source_reference = s.sourceReference.? } },
            );
        }
    }

    if (zgui.button("Request Set Function Breakpoint", .{})) {
        _ = try connection.queue_request(
            .setFunctionBreakpoints,
            protocol.SetFunctionBreakpointsArguments{
                .breakpoints = data.function_breakpoints.items,
            },
            .none,
            .no_data,
        );
    }

    zgui.newLine();
    _ = zgui.inputText("Function name", .{ .buf = &static.name_buf });
    if (zgui.button("Add Function Breakpoint", .{})) {
        const len = std.mem.indexOfScalar(u8, &static.name_buf, 0) orelse static.name_buf.len;
        try data.add_function_breakpoint(.{
            .name = static.name_buf[0..len],
        });

        static.name_buf[0] = 0; // clear
    }
    zgui.sameLine(.{});
    if (zgui.button("Remove Function Breakpoint", .{})) {
        const len = std.mem.indexOfScalar(u8, &static.name_buf, 0) orelse static.name_buf.len;
        data.remove_function_breakpoint(static.name_buf[0..len]);
        static.name_buf[0] = 0; // clear
    }
    draw_table_from_slice_of_struct("Function Breakpoints", protocol.FunctionBreakpoint, data.function_breakpoints.items);
}

fn draw_table_from_slice_of_struct(name: [:0]const u8, comptime T: type, mabye_value: ?[]const T) void {
    const visiable_name = blk: {
        var iter = std.mem.splitAny(u8, name, "##");
        break :blk iter.next().?;
    };
    zgui.text("{s} len({})", .{ visiable_name, (mabye_value orelse &.{}).len });
    const table = std.meta.fields(T);
    const columns_count = std.meta.fields(T).len;
    if (zgui.beginTable(
        name,
        .{ .column = columns_count, .flags = .{
            .resizable = true,
            .context_menu_in_body = true,
            .borders = .{ .inner_h = true, .outer_h = true, .inner_v = true, .outer_v = true },
        } },
    )) {
        inline for (table) |entry| {
            zgui.tableSetupColumn(entry.name, .{});
        }
        zgui.tableHeadersRow();

        if (mabye_value) |value| {
            for (value) |v| {
                zgui.tableNextRow(.{});
                inline for (std.meta.fields(@TypeOf(v))) |field| {
                    const info = @typeInfo(field.type);
                    const field_value = @field(v, field.name);
                    _ = zgui.tableNextColumn();
                    if (info == .pointer and info.pointer.child != u8) { // assume slice
                        for (field_value, 0..) |inner_v, i| {
                            if (i < field_value.len - 1) {
                                zgui.text("{s},", .{anytype_to_string(inner_v, .{})});
                                zgui.sameLine(.{});
                            } else {
                                zgui.text("{s}", .{anytype_to_string(inner_v, .{})});
                            }
                        }
                    } else {
                        zgui.text("{s}", .{anytype_to_string(field_value, .{})});
                    }
                }
            }
        }

        zgui.endTable();
    }
}

fn recursively_draw_object(allocator: std.mem.Allocator, parent: []const u8, name: []const u8, value: std.json.Value) void {
    switch (value) {
        .object => |object| {
            const object_name = allocator.dupeZ(u8, name) catch return;

            if (zgui.treeNode(object_name)) {
                zgui.indent(.{ .indent_w = 1 });
                var iter = object.iterator();
                while (iter.next()) |kv| {
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrintZ(&buf, "{s}.{s}", .{ parent, kv.key_ptr.* }) catch unreachable;
                    recursively_draw_object(allocator, slice, slice, kv.value_ptr.*);
                }
                zgui.unindent(.{ .indent_w = 1 });
                zgui.treePop();
            }
        },
        .array => |array| {
            const array_name = allocator.dupeZ(u8, name) catch return;
            if (zgui.treeNode(array_name)) {
                zgui.indent(.{ .indent_w = 1 });

                for (array.items, 0..) |item, i| {
                    zgui.indent(.{ .indent_w = 1 });
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrintZ(&buf, "{s}[{}]", .{ parent, i }) catch unreachable;
                    recursively_draw_object(allocator, slice, slice, item);
                    zgui.unindent(.{ .indent_w = 1 });
                }

                zgui.unindent(.{ .indent_w = 1 });
                zgui.treePop();
            }
        },
        .number_string, .string => |v| {
            var color = [4]f32{ 1, 1, 1, 1 };
            if (std.mem.endsWith(u8, name, "event") or std.mem.endsWith(u8, name, "command")) {
                color = .{ 0.5, 0.5, 1, 1 };
            }
            zgui.textColored(color, "{s} = \"{s}\"", .{ name, v });
        },
        inline else => |v| {
            zgui.text("{s} = {}", .{ name, v });
        },
    }
}

fn recursively_draw_protocol_object(allocator: std.mem.Allocator, parent: []const u8, name: []const u8, value: protocol.Value) void {
    switch (value) {
        .object => |object| {
            const object_name = allocator.dupeZ(u8, name) catch return;

            if (zgui.treeNode(object_name)) {
                zgui.indent(.{ .indent_w = 1 });
                var iter = object.map.iterator();
                while (iter.next()) |kv| {
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrintZ(&buf, "{s}.{s}", .{ parent, kv.key_ptr.* }) catch unreachable;
                    recursively_draw_protocol_object(allocator, slice, slice, kv.value_ptr.*);
                }
                zgui.unindent(.{ .indent_w = 1 });
                zgui.treePop();
            }
        },
        .array => |array| {
            const array_name = allocator.dupeZ(u8, name) catch return;
            if (zgui.treeNode(array_name)) {
                zgui.indent(.{ .indent_w = 1 });

                for (array.items, 0..) |item, i| {
                    zgui.indent(.{ .indent_w = 1 });
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrintZ(&buf, "{s}[{}]", .{ parent, i }) catch unreachable;
                    recursively_draw_protocol_object(allocator, slice, slice, item);
                    zgui.unindent(.{ .indent_w = 1 });
                }

                zgui.unindent(.{ .indent_w = 1 });
                zgui.treePop();
            }
        },
        .number_string, .string => |v| {
            var color = [4]f32{ 1, 1, 1, 1 };
            if (std.mem.endsWith(u8, name, "event") or std.mem.endsWith(u8, name, "command")) {
                color = .{ 0.5, 0.5, 1, 1 };
            }
            zgui.textColored(color, "{s} = \"{s}\"", .{ name, v });
        },
        inline else => |v| {
            zgui.text("{s} = {}", .{ name, v });
        },
    }
}

fn bool_to_string(opt_bool: ?bool) []const u8 {
    const result = opt_bool orelse return "Unknown";
    return if (result) "True" else "False";
}

fn mabye_string_to_string(string: ?[]const u8) []const u8 {
    return string orelse "";
}

fn protocol_value_to_string(value: protocol.Value) []const u8 {
    switch (value) {
        .string => |string| return string,
        else => @panic("TODO"),
    }
}

const ToStringOptions = struct {
    show_union_name: bool = false,
    value_for_null: []const u8 = "null",
};
fn anytype_to_string(value: anytype, opts: ToStringOptions) []const u8 {
    const static = struct {
        var buffer: [10_000]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    };
    static.fixed.reset();
    return anytype_to_string_recurse(static.fixed.allocator(), value, opts);
}

fn anytype_to_string_recurse(allocator: std.mem.Allocator, value: anytype, opts: ToStringOptions) []const u8 {
    const T = @TypeOf(value);
    if (T == []const u8) {
        return mabye_string_to_string(value);
    }

    switch (@typeInfo(T)) {
        .bool => return bool_to_string(value),
        .float, .int => {
            return std.fmt.allocPrint(allocator, "{}", .{value}) catch unreachable;
        },
        .@"enum" => return @tagName(value),
        .@"union" => {
            switch (value) {
                inline else => |v| {
                    var name_prefix: []const u8 = "";
                    if (opts.show_union_name) {
                        name_prefix = std.fmt.allocPrint(allocator, "{s} = ", .{@tagName(std.meta.activeTag(value))}) catch unreachable;
                    }

                    if (@TypeOf(v) == void) {
                        return @tagName(std.meta.activeTag(value));
                    } else {
                        return std.fmt.allocPrint(allocator, "{s}{s}", .{
                            name_prefix,
                            anytype_to_string_recurse(allocator, v, opts),
                        }) catch unreachable;
                    }
                },
            }
        },
        .@"struct" => |info| {
            var list = std.ArrayList(u8).init(allocator);
            var writer = list.writer();
            inline for (info.fields, 0..) |field, i| {
                writer.print("{s}: {s}", .{
                    field.name,
                    anytype_to_string_recurse(allocator, @field(value, field.name), opts),
                }) catch unreachable;

                if (i < info.fields.len - 1) {
                    _ = writer.write("\n") catch unreachable;
                }
            }

            return list.items;
        },
        .pointer => return @typeName(T),
        .optional => return anytype_to_string_recurse(allocator, value orelse return opts.value_for_null, opts),
        else => {},
    }

    return switch (T) {
        []const u8 => mabye_string_to_string(value),
        // *std.array_hash_map.IndexHeader => {},
        protocol.Value => protocol_value_to_string(value),
        protocol.Object => @panic("TODO"),
        protocol.Array => @panic("TODO"),
        std.debug.SafetyLock => return @typeName(T),
        inline else => @compileError(@typeName(T)),
    };
}

fn get_frame_of_source_content(data: SessionData, content: SessionData.SourceContent) ?protocol.StackFrame {
    for (data.stack_frames.items) |stack| {
        for (stack.data) |frame| {
            const source: protocol.Source = frame.source orelse continue;
            if (content.path) |path| {
                if (path.len > 0 and std.mem.eql(u8, source.path orelse "", path)) {
                    return frame;
                }
            } else if (content.source_reference == source.sourceReference) {
                return frame;
            }
        }
    }

    return null;
}
