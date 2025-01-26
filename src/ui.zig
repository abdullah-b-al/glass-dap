const std = @import("std");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig").SessionData;
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const protocol = @import("protocol.zig");
const utils = @import("utils.zig");
const Args = @import("main.zig").Args;
const begin_debug_sequence = @import("main.zig").begin_debug_sequence;

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
        zgui.dockBuilderDockWindow("Modules", empty);
        zgui.dockBuilderDockWindow("Threads", empty);

        zgui.dockBuilderFinish(dockspace_id);

        _ = zgui.DockSpace("MyDockSpace", viewport.getSize(), .{});
    }

    modules(arena.allocator(), "Modules", data.*);
    threads(arena.allocator(), "Threads", data.*);
    debug_ui(arena.allocator(), "Debug", connection, data, args) catch |err| std.log.err("{}", .{err});

    zgui.backend.draw();

    window.swapBuffers();
}

fn threads(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData) void {
    _ = arena;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const table = .{
        .{ .name = "ID", .field = "id" },
        .{ .name = "Name", .field = "name" },
    };

    const columns_count = std.meta.fields(@TypeOf(table)).len;
    if (zgui.beginTable("Thread Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        inline for (table) |entry| {
            zgui.tableSetupColumn(entry.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.threads.items) |thread| {
            zgui.tableNextRow(.{});
            inline for (table) |entry| {
                _ = zgui.tableNextColumn();
                const value = @field(thread, entry.field);
                zgui.text("{s}", .{anytype_to_string(value)});
            }
        }

        zgui.endTable();
    }
}

fn modules(arena: std.mem.Allocator, name: [:0]const u8, data: SessionData) void {
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
                zgui.text("{s}", .{anytype_to_string(value)});
            }
        }
        zgui.endTable();
    }
}

fn debug_ui(arena: std.mem.Allocator, name: [:0]const u8, connection: *Connection, data: *SessionData, args: Args) !void {
    var open: bool = true;
    zgui.showDemoWindow(&open);

    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

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

    const table = .{
        .{ .name = "Queued Responses", .items = connection.responses.items },
        .{ .name = "Handled Responses", .items = connection.handled_responses.items },
        .{ .name = "Events", .items = connection.events.items },
        .{ .name = "Handled Events", .items = connection.handled_events.items },
    };
    inline for (table) |element| {
        if (zgui.beginTabItem(element.name, .{})) {
            defer zgui.endTabItem();
            if (connection.debug) {
                for (element.items) |resp| {
                    const seq = resp.value.object.get("seq").?.integer;
                    var buf: [512]u8 = undefined;
                    const slice = std.fmt.bufPrint(&buf, "seq[{}]", .{seq}) catch unreachable;
                    recursively_draw_object(arena, slice, slice, resp.value);
                }
            } else {
                zgui.text("Connection debugging is turned off", .{});
            }
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

    draw_table_from_slice_of_struct(protocol.ExceptionBreakpointsFilter, c.exceptionBreakpointFilters);
    draw_table_from_slice_of_struct(protocol.ColumnDescriptor, c.additionalModuleColumns);
    draw_table_from_slice_of_struct(protocol.BreakpointMode, c.breakpointModes);
}

fn manual_requests(connection: *Connection, data: *SessionData, args: Args) !void {
    if (zgui.button("Begin connection", .{})) {
        if (connection.state == .not_spawned) {
            try begin_debug_sequence(connection, args);
        }
    }

    if (zgui.button("end connection: disconnect", .{})) {
        const seq = try connection.end_session(.disconnect);
        try connection.wait_for_response(seq);
        try connection.handle_disconnect_response(seq);
    }

    if (zgui.button("end connection: terminate", .{})) {
        _ = try connection.end_session(.terminate);
    }

    if (zgui.button("Threads", .{})) {
        const seq = try connection.send_threads_request(null);
        try connection.wait_for_response(seq);
        try data.handle_response_threads(connection, seq);
    }
}

fn draw_table_from_slice_of_struct(comptime T: type, mabye_value: ?[]T) void {
    zgui.text("== {s} len({}) ==", .{ @typeName(T), (mabye_value orelse &.{}).len });
    const table = std.meta.fields(T);
    const columns_count = std.meta.fields(T).len;
    if (zgui.beginTable(@typeName(T), .{ .column = columns_count, .flags = .{ .resizable = true, .context_menu_in_body = true } })) {
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
                                zgui.text("{s},", .{anytype_to_string(inner_v)});
                                zgui.sameLine(.{});
                            } else {
                                zgui.text("{s}", .{anytype_to_string(inner_v)});
                            }
                        }
                    } else {
                        zgui.text("{s}", .{anytype_to_string(field_value)});
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

fn anytype_to_string(value: anytype) []const u8 {
    const static = struct {
        var buf: [10_000]u8 = undefined;
    };

    switch (@typeInfo(@TypeOf(value))) {
        .@"enum" => return @tagName(value),
        .@"union" => return @tagName(std.meta.activeTag(value)),
        .optional => return anytype_to_string(value orelse return "null"),
        else => {},
    }

    return switch (@TypeOf(value)) {
        bool => bool_to_string(value),
        []const u8 => mabye_string_to_string(value),
        protocol.Value => protocol_value_to_string(value),
        i32 => std.fmt.bufPrint(&static.buf, "{}", .{value}) catch unreachable,
        inline else => @compileError(@typeName(@TypeOf(value))),
    };
}
