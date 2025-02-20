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
const handlers = @import("handlers.zig");
const Callbacks = handlers.Callbacks;
const config = @import("config.zig");
const log = std.log.scoped(.ui);
const Dir = std.fs.Dir;
const fs = std.fs;
const meta = std.meta;
const assets = @import("assets");
const plot = zgui.plot;
const DebugAllocators = @import("main.zig").DebugAllocators;
const time = std.time;
const mem = std.mem;

const Path = std.BoundedArray(u8, std.fs.max_path_bytes);

const State = struct {
    arena_state: std.heap.ArenaAllocator,
    notifications: Notifications,

    render_frames: u8 = 4,
    active_source: ActiveSource = .defualt,
    icons_solid: zgui.Font = undefined,
    debug_ui: bool = @import("builtin").mode == .Debug,
    plot_demo: bool = false,
    imgui_demo: bool = false,

    files: Files = undefined,
    home_path: Path = Path.init(0) catch unreachable,
    picker: ?Picker = null,

    launch_config_index: ?usize = null,

    variable_edit: ?struct {
        reference: SessionData.VariableReference,
        index: usize,
        buffer: [1024:0]u8 = .{0} ** 1024,
    } = null,

    // handled in ui_tick
    ask_for_launch_config: bool = false,
    begin_session: bool = false,
    update_active_source_to_top_of_stack: bool = false,

    // handled in a widget
    scroll_to_active_line: bool = false,
    waiting_for_scopes: bool = false,
    waiting_for_variables: bool = false,
    waiting_for_stack_trace: bool = false,

    pub fn arena(s: *State) std.mem.Allocator {
        return s.arena_state.allocator();
    }
};

pub var state = State{
    .arena_state = undefined,
    .notifications = undefined,
};

pub fn continue_rendering() void {
    state.render_frames = @max(state.render_frames, 30);
}

var zgui_mouse_cursor_pos_callback: ?glfw.CursorPosFn = null;
var zgui_mouse_button_callback: ?glfw.MouseButtonFn = null;
var zgui_key_callback: ?glfw.KeyFn = null;
var zgui_scroll_callback: ?glfw.ScrollFn = null;

pub fn key_callback(window: *glfw.Window, key: glfw.Key, scancode: c_int, action: glfw.Action, mods: glfw.Mods) callconv(.C) void {
    continue_rendering();
    zgui_key_callback.?(window, key, scancode, action, mods);
}
pub fn mouse_cursor_pos_callback(window: *glfw.Window, xpos: f64, ypos: f64) callconv(.C) void {
    continue_rendering();
    zgui_mouse_cursor_pos_callback.?(window, xpos, ypos);
}

pub fn scroll_callback(window: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.C) void {
    continue_rendering();
    zgui_scroll_callback.?(window, xoffset, yoffset);
}

pub fn mouse_button_callback(window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.C) void {
    continue_rendering();
    zgui_mouse_button_callback.?(window, button, action, mods);
}

pub fn window_size_callback(_: *glfw.Window, _: c_int, _: c_int) callconv(.C) void {
    continue_rendering();
}

pub fn window_focus_callback(_: *glfw.Window, _: glfw.Bool) callconv(.C) void {
    continue_rendering();
}

pub fn init_ui(allocator: std.mem.Allocator, cwd: []const u8) !*glfw.Window {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    state = State{
        .arena_state = std.heap.ArenaAllocator.init(allocator),
        .notifications = Notifications.init(allocator),
        .files = Files.init(allocator, cwd),
        .home_path = try Path.fromSlice(env_map.get("HOME") orelse ""),
    };

    try glfw.init();

    const gl_major = 4;
    const gl_minor = 0;
    glfw.windowHint(.context_version_major, gl_major);
    glfw.windowHint(.context_version_minor, gl_minor);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.opengl_forward_compat, true);
    glfw.windowHint(.client_api, .opengl_api);
    glfw.windowHint(.doublebuffer, true);

    const window = try glfw.Window.create(1000, 1000, "glass-dap", null);
    window.setSizeLimits(400, 400, -1, -1);

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    // opengl
    try zopengl.loadCoreProfile(glfw.getProcAddress, gl_major, gl_minor);

    // imgui
    zgui.init(allocator);
    plot.init();
    zgui.io.setConfigFlags(.{ .dock_enable = true });

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    {
        var font_config = zgui.FontConfig.init();
        const size = std.math.floor(24.0 * scale_factor);
        font_config.font_data_owned_by_atlas = false;

        state.icons_solid = zgui.io.addFontFromMemoryWithConfig(
            assets.jet_brains,
            size,
            font_config,
            null,
        );
        font_config.merge_mode = true;
        _ = zgui.io.addFontFromMemoryWithConfig(
            assets.font_awesome_free_solid,
            size,
            font_config,
            &.{
                0xF111, '',
                0, // null byte
            },
        );
    }

    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);
    zgui_mouse_cursor_pos_callback = glfw.setCursorPosCallback(window, mouse_cursor_pos_callback);
    std.debug.assert(zgui_mouse_cursor_pos_callback != null);

    zgui_mouse_button_callback = glfw.setMouseButtonCallback(window, mouse_button_callback);
    std.debug.assert(zgui_mouse_button_callback != null);

    zgui_scroll_callback = glfw.setScrollCallback(window, scroll_callback);
    std.debug.assert(zgui_scroll_callback != null);

    zgui_key_callback = glfw.setKeyCallback(window, key_callback);
    std.debug.assert(zgui_key_callback != null);

    _ = glfw.setWindowSizeCallback(window, window_size_callback);
    _ = glfw.setWindowFocusCallback(window, window_focus_callback);

    return window;
}

pub fn deinit_ui(window: *glfw.Window) void {
    state.files.deinit();
    state.notifications.deinit();
    state.arena_state.deinit();

    zgui.backend.deinit();
    plot.deinit();
    zgui.deinit();
    window.destroy();
    glfw.terminate();
}

pub fn ui_tick(gpas: *DebugAllocators, window: *glfw.Window, callbacks: *Callbacks, connection: *Connection, data: *SessionData, argv: Args) void {
    if (gpas.timer.read() / time.ns_per_s >= gpas.interval_seconds) {
        inline for (meta.fields(DebugAllocators)) |field| {
            if (field.type == DebugAllocators.Allocator) {
                const alloc = &@field(gpas, field.name);
                alloc.snap() catch return;
            }
        }
        gpas.timer.reset();
    }

    glfw.pollEvents();
    if (state.render_frames == 0) return;
    defer state.render_frames -= 1;

    defer _ = state.arena_state.reset(.retain_capacity);

    const gl = zopengl.bindings;
    gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0, 0, 0, 1.0 });

    const fb_size = window.getFramebufferSize();

    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

    if (state.ask_for_launch_config) {
        state.ask_for_launch_config = !pick("Pick Launch configuration", config.launch, .launch_config);
    }

    if (state.begin_session) {
        state.begin_session = !(request.begin_session(state.arena(), connection, data) catch |err| blk: {
            log_err(err, @src());
            break :blk true;
        });
    }

    if (state.update_active_source_to_top_of_stack) blk: {
        state.update_active_source_to_top_of_stack = false;
        // TODO: Check if the thread of the active_source is invalid if so update it
        if (state.active_source.get_thread(data)) |thread| {
            if (thread.stack.items.len > 0) {
                const source = thread.stack.items[0].value.source orelse break :blk;
                const id = state.active_source.get_id() orelse break :blk;
                const eql = utils.source_is(source, id);

                if (!eql) {
                    state.active_source.set_source(thread.id, source);
                    state.scroll_to_active_line = true;
                }
            }
        }
    }

    if (get_action()) |act| {
        handle_action(act, callbacks, data, connection) catch return;
    }

    // resizes the dockspace to the whole window
    const id_dockspace = zgui.DockSpaceOverViewport(0, zgui.getMainViewport(), .{});

    const static = struct {
        var built_layout = false;
    };

    if (!static.built_layout) {
        static.built_layout = true;

        const viewport = zgui.getMainViewport();

        const top_left = zgui.dockBuilderAddNode(id_dockspace, .{});
        zgui.dockBuilderSetNodeSize(top_left, viewport.getSize());

        var id_source = top_left;
        const id_output = zgui.dockBuilderSplitNode(id_source, .down, 0.30, null, &id_source);
        const id_threads = zgui.dockBuilderSplitNode(id_source, .right, 0.30, null, &id_source);

        // tabbed, right of Source Code (top right)
        zgui.dockBuilderDockWindow("Threads", id_threads);
        zgui.dockBuilderDockWindow("Sources", id_threads);
        zgui.dockBuilderDockWindow("Variables", id_threads);
        zgui.dockBuilderDockWindow("Breakpoints", id_threads);

        // left of Threads (top left)
        zgui.dockBuilderDockWindow("Source Code", id_source);

        // below source code
        zgui.dockBuilderDockWindow("Output", id_output);

        zgui.dockBuilderDockWindow("Debug General", id_source);
        zgui.dockBuilderDockWindow("Debug Modules", id_source);
        zgui.dockBuilderDockWindow("Debug Threads", id_source);
        zgui.dockBuilderDockWindow("Debug Stack Frames", id_source);
        zgui.dockBuilderDockWindow("Debug Scopes", id_source);
        zgui.dockBuilderDockWindow("Debug Variables", id_source);
        zgui.dockBuilderDockWindow("Debug Breakpoints", id_source);
        zgui.dockBuilderDockWindow("Debug Sources", id_source);
        zgui.dockBuilderDockWindow("Debug Sources Content", id_source);

        zgui.dockBuilderFinish(id_dockspace);

        _ = zgui.DockSpace("Main DockSpace", viewport.getSize(), .{});
    }

    notifications();
    source_code("Source Code", data, connection);
    output("Output", data.*, connection);
    threads("Threads", callbacks, data, connection);
    sources("Sources", data, connection);
    variables("Variables", callbacks, data, connection);
    breakpoints("Breakpoints", data.*, connection);

    debug_ui(gpas, callbacks, connection, data, argv) catch |err| std.log.err("{}", .{err});

    zgui.backend.draw();

    window.swapBuffers();
}

fn notifications() void {
    {
        var i: usize = 0;
        while (i < state.notifications.messages.items.len) {
            const entry = &state.notifications.messages.items[i];
            const read: isize = @intCast(entry.timer.read() / time.ns_per_ms);
            if (read >= entry.time_ms) {
                const item = state.notifications.messages.orderedRemove(i);
                state.notifications.allocator.free(item.message);
            } else {
                i += 1;
            }
        }
    }

    if (state.notifications.messages.items.len == 0) {
        return;
    }

    const static = struct {
        var x: ?f32 = null;
        var y: ?f32 = null;
    };

    const size = zgui.io.getDisplaySize();
    zgui.setNextWindowPos(.{
        .x = static.x orelse size[0],
        .y = static.y orelse size[1],
        .cond = .always,
    });

    defer zgui.end();
    if (!zgui.begin("##Notifications", .{
        .flags = .{
            .always_auto_resize = true,
            .no_title_bar = true,
            .no_resize = true,
            .no_scrollbar = true,
            .no_collapse = true,
        },
    })) return;

    for (state.notifications.messages.items, 0..) |entry, i| {
        zgui.text("{s}", .{entry.message});
        if (i + 1 != state.notifications.messages.items.len) {
            zgui.separator();
        }
        continue_rendering();
    }
    const win_size = zgui.getWindowSize();
    static.x = size[0] - win_size[0];
    static.y = size[1] - win_size[1];
}

fn source_code(name: [:0]const u8, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const source_id, const content = state.active_source.get_source_content(data) orelse {
        // Let's try again next frame
        state.active_source.set_source_content(state.arena(), data, connection) catch |err| {
            log.err("{}", .{err});
        };
        return;
    };

    const frame = get_frame_of_source_content(data.*, source_id);

    if (!zgui.beginTable("Source Code Table", .{
        .column = 2,
        .flags = .{
            .sizing = .fixed_fit,
            .borders = .{
                .inner_h = false,
                .outer_h = false,
                .inner_v = true,
                .outer_v = false,
            },
        },
    })) return;
    defer zgui.endTable();

    const dl = zgui.getWindowDrawList();
    const line_height = zgui.getTextLineHeightWithSpacing();
    const window_width = zgui.getWindowWidth();

    var iter = std.mem.splitScalar(u8, content.content, '\n');
    var line_number: usize = 0;
    while (iter.next()) |line| {
        defer line_number += 1;
        const int_line: i32 = @truncate(@as(i64, @intCast(line_number)));
        const active_line = if (frame) |f| (f.line == line_number) else false;

        if (active_line) {
            state.active_source.line = int_line;
        }

        zgui.tableNextRow(.{});

        if (zgui.tableSetColumnIndex(0)) { // line numbers
            if (active_line) {
                const pos = zgui.getCursorScreenPos();
                dl.addRectFilled(.{
                    .pmin = pos,
                    .pmax = .{ pos[0] + window_width, pos[1] + line_height },
                    .col = color_u32(.text_selected_bg),
                });
            }
            if (zgui.selectable(
                tmp_name("{} ##Source Code Selectable", .{line_number + 1}),
                .{ .flags = .{ .span_all_columns = true } },
            )) {
                breakpoint_toggle(source_id, int_line, data, connection);
            }

            if (zgui.isItemClicked(.right)) {
                // TODO
            }

            const bp_count = breakpoint_in_line(data, source_id, int_line);
            if (bp_count > 0) {
                zgui.sameLine(.{ .spacing = 0 });
                zgui.textColored(.{ 1, 0, 0, 1 }, "", .{});
                if (bp_count > 1) {
                    zgui.sameLine(.{ .spacing = 0 });
                    zgui.textColored(.{ 1, 0, 0, 1 }, "{}", .{bp_count});
                }
            }
        }

        var pos: [2]f32 = .{ 0, 0 };
        if (zgui.tableSetColumnIndex(1)) { // text
            pos = zgui.getCursorScreenPos();
            zgui.text("{s}", .{line});
        }

        if (active_line) {
            const f = frame.?;
            if (f.column < line.len) {
                const column: usize = @intCast(@max(0, f.column - 1));
                const size = zgui.calcTextSize(line[0..column], .{});
                const char = zgui.calcTextSize(line[column .. column + 1], .{});

                const x = pos[0] + size[0];
                const y = pos[1] + size[1];
                dl.addLine(.{
                    .p1 = .{ x, y },
                    .p2 = .{ x + char[0], y },
                    .col = color_u32(.text),
                    .thickness = 1,
                });
            }

            if (state.scroll_to_active_line) {
                state.scroll_to_active_line = false;
                zgui.setScrollHereY(.{ .center_y_ratio = 0.5 });
            }
        }
    }
}

fn sources(name: [:0]const u8, data: *SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Sources Tabs", .{})) return;

    if (zgui.beginTabItem("Files", .{})) files_blk: {
        defer zgui.endTabItem();
        if (state.files.entries.items.len == 0) {
            state.files.fill() catch |err| {
                zgui.text("{}", .{err});
                break :files_blk;
            };
        }

        for (state.files.entries.items) |entry| {
            const s_name = if (entry.kind == .directory)
                tmp_name("{s}/", .{entry.name})
            else
                tmp_name("{s}", .{entry.name});
            if (zgui.selectable(s_name, .{})) {
                if (entry.kind == .directory) {
                    state.files.cd(entry) catch break :files_blk;
                    break; // cd frees the files_entries
                } else {
                    state.files.open(data, entry) catch break :files_blk;
                }
            }
        }
    }

    if (zgui.beginTabItem("Loaded Sources", .{})) {
        defer zgui.endTabItem();

        const fn_name = @src().fn_name;
        var buf: [std.fs.max_path_bytes]u8 = undefined;

        for (data.sources.values()) |source| {
            const source_path = if (source.value.path) |path| tmp_shorten_path(path) else null;
            const label = if (source_path) |path|
                std.fmt.bufPrintZ(&buf, "{s}##" ++ fn_name, .{path}) catch return
            else if (source.value.sourceReference) |ref|
                std.fmt.bufPrintZ(&buf, "{s}({})##" ++ fn_name, .{ source.value.name orelse "", ref }) catch return
            else
                return;

            if (zgui.button(label, .{})) {
                if (thread_of_source(source.value, data.*)) |thread| {
                    state.active_source.set_source(thread.id, source.value);
                    state.scroll_to_active_line = true;
                } else {
                    state.active_source.set_source(null, source.value);
                    state.scroll_to_active_line = true;
                }
            }
        }
    }
}

fn variables(name: [:0]const u8, callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const thread = state.active_source.get_thread(data) orelse return;
    if (thread.state != .stopped) return;

    const frame = state.active_source.get_frame(data) orelse return;
    const scopes = thread.scopes.get(@enumFromInt(frame.id)) orelse {
        if (state.waiting_for_scopes) return;

        request.scopes(connection, thread.id, @enumFromInt(frame.id), false) catch return;

        const static = struct {
            fn func(_: *SessionData, _: *Connection, _: ?Connection.RawMessage) void {
                state.waiting_for_scopes = false;
            }
        };

        handlers.callback(callbacks, .success, .{ .response = .scopes }, null, static.func) catch return;
        state.waiting_for_scopes = true;
        return;
    };

    var scopes_name = std.StringArrayHashMap(void).init(state.arena());
    for (scopes.value) |scope| {
        scopes_name.put(scope.name, {}) catch return;
    }

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Variables Tab Bar", .{})) return;
    for (scopes_name.keys()) |n| {
        if (!zgui.beginTabItem(tmp_name("{s}", .{n}), .{})) continue;
        defer zgui.endTabItem();

        for (scopes.value) |scope| {
            if (!std.mem.eql(u8, n, scope.name)) continue;
            const reference: SessionData.VariableReference = @enumFromInt(scope.variablesReference);
            const vars = thread.variables.get(reference) orelse {
                request_or_wait_for_variables(connection, thread, callbacks, @enumFromInt(scope.variablesReference));
                continue;
            };

            for (vars.value, 0..) |v, i| {
                variables_node(connection, data, callbacks, thread, v, reference, i);
            }
        }
    }
}

fn variables_node(connection: *Connection, data: *SessionData, callbacks: *Callbacks, thread: *const SessionData.Thread, variable: protocol.Variable, reference: SessionData.VariableReference, index: usize) void {
    const has_evaluate_name = variable.evaluateName != null;

    const static = struct {
        pub fn variable_type(v: protocol.Variable) void {
            const style = zgui.getStyle();
            if (v.type) |t| {
                zgui.pushStyleColor4f(.{ .idx = .text, .c = style.getColor(.text_disabled) });
                defer zgui.popStyleColor(.{ .count = 1 });
                zgui.text(": {s}", .{t});
            }
        }
    };

    const widget: enum { input_text, value, node } =
        if (state.variable_edit != null)
        .input_text
    else if (variable.variablesReference > 0)
        .node
    else
        .value;

    widget: switch (widget) {
        .input_text => {
            var edit = &state.variable_edit.?;
            if (edit.index != index or edit.reference != reference) {
                continue :widget .value;
            } else {
                zgui.text("{s}", .{variable.name});
                zgui.sameLine(.{ .spacing = 0 });
                static.variable_type(variable);

                zgui.sameLine(.{});
                zgui.setNextItemWidth(zgui.getContentRegionMax()[0]);
                _ = zgui.inputText(
                    tmp_name("##InputText {} {s} {}", .{ reference, variable.name, index }),
                    .{ .buf = &edit.buffer, .flags = .{} },
                );

                if (zgui.isKeyPressed(.enter, false)) {
                    const new_value_len = std.mem.indexOfScalar(u8, &edit.buffer, 0) orelse edit.buffer.len;
                    const new_value = edit.buffer[0..new_value_len];
                    request.set_variable(
                        connection,
                        thread.id,
                        reference,
                        variable.name,
                        new_value,
                        has_evaluate_name,
                    ) catch return;

                    state.variable_edit = null;
                }
            }
        },
        .value => {
            if (variable.variablesReference > 0) {
                continue :widget .node;
            }

            const label = tmp_name("##Selecable {} {s} {}", .{ reference, variable.name, index });
            if (zgui.selectable(label, .{})) {
                state.variable_edit = .{
                    .index = index,
                    .reference = reference,
                };
                const value_len = @min(state.variable_edit.?.buffer.len, variable.value.len);
                mem.copyForwards(
                    u8,
                    &state.variable_edit.?.buffer,
                    variable.value[0..value_len],
                );
            }

            zgui.sameLine(.{});
            zgui.text("{s}", .{variable.name});
            zgui.sameLine(.{ .spacing = 0 });
            static.variable_type(variable);
            zgui.sameLine(.{});
            zgui.text("{s}", .{variable.value});
        },
        .node => {
            const node_opened = zgui.treeNode(tmp_name("{s}##Node {} {}", .{ variable.name, reference, index }));
            zgui.sameLine(.{ .spacing = 0 });
            static.variable_type(variable);

            if (!node_opened) return;
            defer zgui.treePop();

            std.debug.assert(variable.variablesReference > 0);
            const nested_reference: SessionData.VariableReference = @enumFromInt(variable.variablesReference);
            const nested_variables = thread.variables.get(nested_reference) orelse {
                request_or_wait_for_variables(connection, thread, callbacks, nested_reference);
                return;
            };
            for (nested_variables.value, 0..) |nested, i| {
                if (nested.variablesReference > 0) {
                    zgui.indent(.{ .indent_w = 1 });
                    defer zgui.unindent(.{ .indent_w = 1 });
                }
                variables_node(connection, data, callbacks, thread, nested, nested_reference, i);
            }
        },
    }
}

fn breakpoints(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;

    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.breakpoints.items, 0..) |item, i| {
        const origin = switch (item.value.origin) {
            .event => "event",
            .source => |id| tmp_shorten_path(anytype_to_string(id, .{})),
            .function => "function",
        };

        const line = item.value.breakpoint.line orelse continue;
        const n = tmp_name("{s} {?}##{}", .{ origin, line + 1, i });
        if (zgui.selectable(n, .{})) {}
    }
}

fn threads(name: [:0]const u8, callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    { // buttons
        // line 1
        if (zgui.button("Select All", .{})) {
            var iter = data.threads.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.selected = false;
            }
        }

        zgui.sameLine(.{});
        if (zgui.button("Deselect All", .{})) {
            var iter = data.threads.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.selected = true;
            }
        }

        // line 2

        if (zgui.button("Pause", .{})) {
            request.pause(data.*, connection);
        }
        zgui.sameLine(.{});
        if (zgui.button("Continue", .{})) {
            request.continue_threads(data.*, connection);
        }

        // line 3
        if (zgui.button("Next Line", .{})) {
            request.step(callbacks, data.*, connection, .next, .line);
        }
        zgui.sameLine(.{});
        if (zgui.button("Next Statement", .{})) {
            request.step(callbacks, data.*, connection, .next, .statement);
        }
        zgui.sameLine(.{});
        if (zgui.button("Next Instruction", .{})) {
            request.step(callbacks, data.*, connection, .next, .instruction);
        }

        // line 4
        if (zgui.button("In Line", .{})) {
            request.step(callbacks, data.*, connection, .in, .line);
        }
        zgui.sameLine(.{});
        if (zgui.button("In Statement", .{})) {
            request.step(callbacks, data.*, connection, .in, .statement);
        }
        zgui.sameLine(.{});
        if (zgui.button("In Instruction", .{})) {
            request.step(callbacks, data.*, connection, .in, .instruction);
        }

        // line 5
        if (zgui.button("Out Line", .{})) {
            request.step(callbacks, data.*, connection, .out, .line);
        }
        zgui.sameLine(.{});
        if (zgui.button("Out Statement", .{})) {
            request.step(callbacks, data.*, connection, .out, .statement);
        }
        zgui.sameLine(.{});
        if (zgui.button("Out Instruction", .{})) {
            request.step(callbacks, data.*, connection, .out, .instruction);
        }
    } // buttons

    _ = zgui.beginChild("Code View", .{});
    defer zgui.endChild();

    var style = zgui.getStyle();
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;
        const style_idx: zgui.StyleCol = if (thread.selected) .text else .text_disabled;
        zgui.pushStyleColor4f(.{ .idx = .text, .c = style.getColor(style_idx) });
        defer zgui.popStyleColor(.{ .count = 1 });

        _ = zgui.checkbox(tmp_name("##Selection {s} {}", .{ thread.name, thread.id }), .{ .v = &thread.selected });
        zgui.sameLine(.{});

        const stack_name = tmp_name("{s} #{}", .{ thread.name, thread.id });
        if (zgui.treeNode(stack_name)) {
            defer zgui.treePop();

            if (!thread.requested_stack) {
                request_or_wait_for_stack_trace(connection, thread, callbacks);
                continue;
            }

            zgui.indent(.{ .indent_w = 1 });

            for (thread.stack.items, 0..) |frame, i| {
                if (zgui.selectable(tmp_name("{s}##{}", .{ frame.value.name, i }), .{})) {
                    if (frame.value.source) |s| {
                        state.active_source.set_source(thread.id, s);
                        state.scroll_to_active_line = true;
                    }
                }
            }

            zgui.unindent(.{ .indent_w = 1 });
        }
    }
}

fn output(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;

    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const Category = meta.Child(utils.get_field_type(SessionData.Output, "category"));
    const categories = [_]Category{
        .stdout,
        .stderr,
        .console,
    };

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Output Tabs", .{})) return;

    if (zgui.beginTabItem("All", .{})) {
        defer zgui.endTabItem();
        for (data.output.items) |item| {
            zgui.text("{s}", .{item.output});
        }
    }

    for (categories) |category| {
        if (zgui.beginTabItem(@tagName(category), .{})) {
            defer zgui.endTabItem();
            for (data.output.items) |item| {
                if (meta.eql(item.category, category)) {
                    zgui.text("{s}", .{item.output});
                }
            }
        }
    }
}

fn debug_threads(name: [:0]const u8, data: SessionData, connection: *Connection) void {
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
        defer zgui.endTable();
        inline for (table) |entry| {
            zgui.tableSetupColumn(entry.name, .{});
        }
        zgui.tableHeadersRow();

        var iter = data.threads.iterator();
        while (iter.next()) |entry| {
            const thread = entry.value_ptr;
            zgui.tableNextRow(.{});
            { // column 1
                _ = zgui.tableNextColumn();
                if (zgui.button(tmp_name("Get Full State##{*}", .{entry.key_ptr}), .{})) {
                    request.get_thread_state(connection, thread.id) catch return;
                }
                if (zgui.button(tmp_name("Stack Trace##{*}", .{entry.key_ptr}), .{})) {
                    const args = protocol.StackTraceArguments{
                        .threadId = @intFromEnum(thread.id),
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
                if (zgui.button(tmp_name("Scopes##{*}", .{entry.key_ptr}), .{})) {
                    for (thread.stack.items) |frame| {
                        request.scopes(connection, thread.id, @enumFromInt(frame.value.id), false) catch return;
                    }
                }

                zgui.sameLine(.{});
                if (zgui.button(tmp_name("Variables##{*}", .{entry.key_ptr}), .{})) {
                    for (thread.scopes.values()) |scopes| {
                        for (scopes.value) |scope| {
                            _ = connection.queue_request(
                                .variables,
                                protocol.VariablesArguments{ .variablesReference = scope.variablesReference },
                                .none,
                                .{ .variables = .{
                                    .thread_id = thread.id,
                                    .variables_reference = @enumFromInt(scope.variablesReference),
                                } },
                            ) catch return;
                        }
                    }
                }
            } // column 1

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.id, .{})});

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.name, .{})});

            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(thread.state, .{})});
        }
    }
}

fn debug_general(gpas: *const DebugAllocators, name: [:0]const u8, data: *SessionData, connection: *Connection, args: Args) !void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Debug Tabs", .{})) return;

    if (zgui.beginTabItem("Memory Usage", .{})) blk: {
        defer zgui.endTabItem();
        continue_rendering();

        zgui.text("Debug Connection: {}", .{connection.debug});

        if (zgui.beginTable("Memory Usage Table", .{ .column = 4, .flags = .{
            .sizing = .fixed_fit,
        } })) {
            defer zgui.endTable();

            inline for (meta.fields(DebugAllocators)) |field| {
                if (field.type == DebugAllocators.Allocator) {
                    zgui.tableNextRow(.{});
                    const alloc = @field(gpas, field.name);
                    const bytes = alloc.gpa.total_requested_bytes;
                    if (@TypeOf(bytes) != void) {
                        const color = [4]f32{ 0.5, 0.5, 1, 1 };
                        _ = zgui.tableNextColumn();
                        zgui.text("{s}", .{field.name});

                        _ = zgui.tableNextColumn();
                        zgui.text("{}", .{bytes});
                        zgui.sameLine(.{ .spacing = 0 });
                        zgui.textColored(color, "B", .{});

                        _ = zgui.tableNextColumn();
                        zgui.text("{}", .{bytes / 1024});
                        zgui.sameLine(.{ .spacing = 0 });
                        zgui.textColored(color, "KiB", .{});

                        _ = zgui.tableNextColumn();
                        zgui.text("{}", .{bytes / 1024 / 1024});
                        zgui.sameLine(.{ .spacing = 0 });
                        zgui.textColored(color, "MiB", .{});
                    }
                }
            }
        }

        if (!plot.beginPlot("Memory Usage", .{ .w = -1, .h = -1 })) break :blk;
        defer plot.endPlot();

        plot.setupAxis(.x1, .{ .label = "Seconds" });
        const max: f64 = @floatFromInt(@max(60, gpas.general.snapshots.len));
        const min = max - 60;
        plot.setupAxisLimits(.x1, .{ .min = min, .max = max, .cond = .always });
        plot.setupAxis(.y1, .{ .label = "MiB" });
        plot.setupAxisLimits(.y1, .{ .min = 0, .max = 10, .cond = .once });

        inline for (meta.fields(DebugAllocators)) |field| {
            if (field.type == DebugAllocators.Allocator) {
                const alloc = @field(gpas, field.name);
                plot.pushStyleVar1f(.{ .idx = .fill_alpha, .v = 0.25 });
                plot.plotShaded(tmp_name("{s}", .{field.name}), f64, .{
                    .xv = alloc.snapshots.items(.index),
                    .yv = alloc.snapshots.items(.memory),
                });
                plot.plotLine(tmp_name("{s}", .{field.name}), f64, .{
                    .xv = alloc.snapshots.items(.index),
                    .yv = alloc.snapshots.items(.memory),
                });
                plot.popStyleVar(.{ .count = 1 });
            }
        }
    }

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
            const slice = std.fmt.bufPrint(&buf, "seq({?}){s}", .{ item.debug_request_seq, @tagName(item.command) }) catch unreachable;
            recursively_draw_protocol_object(state.arena(), slice, slice, .{ .object = item.args });
        }
    }

    const table = .{
        .{ .name = "Queued Messages", .items = connection.messages.items },
        .{ .name = "Debug Handled Responses", .items = connection.debug_handled_responses.items },
        .{ .name = "Debug Failed Messages", .items = connection.debug_failed_messages.items },
        .{ .name = "Debug Handled Events", .items = connection.debug_handled_events.items },
    };
    inline for (table) |element| {
        if (zgui.beginTabItem(element.name, .{})) {
            defer zgui.endTabItem();
            for (element.items) |resp| {
                const seq = resp.value.object.get("seq").?.integer;
                var buf: [512]u8 = undefined;
                const slice = std.fmt.bufPrint(&buf, "seq[{}]", .{seq}) catch unreachable;
                recursively_draw_object(state.arena(), slice, slice, resp.value);
            }
        }
    }

    if (zgui.beginTabItem("Handled Responses", .{})) {
        defer zgui.endTabItem();
        draw_table_from_slice_of_struct(@typeName(Connection.HandledResponse), Connection.HandledResponse, connection.handled_responses.items);
    }

    if (zgui.beginTabItem("Handled Events", .{})) {
        defer zgui.endTabItem();
        for (connection.handled_events.items) |item| {
            zgui.text("{s}", .{@tagName(item.event)});
        }
    }

    if (zgui.beginTabItem("Queued Requests", .{})) {
        defer zgui.endTabItem();
        draw_table_from_slice_of_struct(@typeName(Connection.Request), Connection.Request, connection.queued_requests.items);
    }
}

fn debug_modules(name: [:0]const u8, data: SessionData) void {
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

        for (data.modules.values()) |mo| {
            const module = mo.value;
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

fn debug_stack_frames(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;

        var buf: [64]u8 = undefined;
        const n = std.fmt.bufPrintZ(&buf, "Thread ID {}##variables slice", .{thread.id}) catch return;
        draw_table_from_slice_of_struct(n, utils.MemObject(protocol.StackFrame), thread.stack.items);
        zgui.newLine();
    }
}

fn debug_scopes(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.threads.values()) |thread| {
        for (thread.scopes.keys(), thread.scopes.values()) |frame, item| {
            var buf: [64]u8 = undefined;
            const n = std.fmt.bufPrintZ(&buf, "Frame ID {}##scopes slice", .{frame}) catch return;
            draw_table_from_slice_of_struct(n, protocol.Scope, item.value);
            zgui.newLine();
        }
    }
}

fn debug_variables(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.threads.values()) |thread| {
        for (thread.variables.keys(), thread.variables.values()) |ref, vars| {
            var buf: [64]u8 = undefined;
            const n = std.fmt.bufPrintZ(&buf, "Reference {}##variables slice", .{ref}) catch return;
            draw_table_from_slice_of_struct(n, protocol.Variable, vars.value);
            zgui.newLine();
        }
    }
}

fn debug_breakpoints(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    draw_table_from_slice_of_struct("breakpoints", utils.MemObject(SessionData.Breakpoint), data.breakpoints.items);
}

fn debug_sources(name: [:0]const u8, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const columns_count = std.meta.fields(protocol.Source).len + 1;
    if (zgui.beginTable("Source Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        zgui.tableSetupColumn("Actions", .{});
        inline for (std.meta.fields(protocol.Source)) |field| {
            zgui.tableSetupColumn(field.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.sources.values(), 0..) |source, i| {
            const button_name = std.fmt.allocPrintZ(state.arena(), "Get Content##{}", .{i}) catch return;
            zgui.tableNextRow(.{});
            _ = zgui.tableNextColumn();
            if (zgui.button(button_name, .{})) blk: {
                if (source.value.path) |path| {
                    const key, const new_source = io.open_file_as_source_content(state.arena(), path) catch break :blk;
                    data.set_source_content(key, new_source) catch break :blk;
                } else {
                    _ = connection.queue_request(
                        .source,
                        protocol.SourceArguments{
                            .source = source.value,
                            .sourceReference = source.value.sourceReference.?,
                        },
                        .none,
                        .{ .source = .{ .path = source.value.path, .source_reference = source.value.sourceReference.? } },
                    ) catch return;
                }
            }

            inline for (std.meta.fields(protocol.Source)) |field| {
                _ = zgui.tableNextColumn();
                const value = @field(source.value, field.name);
                zgui.text("{s}", .{anytype_to_string(value, .{})});
            }
        }
        zgui.endTable();
    }
}

fn debug_sources_content(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    zgui.text("len {}", .{data.sources_content.count()});
    zgui.newLine();

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Sources Content Tabs", .{})) return;

    var buf: [512:0]u8 = undefined;
    var sources_iter = data.sources_content.iterator();
    var i: usize = 0;
    while (sources_iter.next()) |entry| : (i += 1) {
        const key = entry.key_ptr.*;
        const content = entry.value_ptr.*;

        const tab_name = switch (key) {
            .path => |path| std.fmt.bufPrintZ(&buf, "{s}##Sources", .{path}) catch continue,
            else => std.fmt.bufPrintZ(&buf, "{}##Sources", .{i}) catch continue,
        };

        const active_line: ?i32 = blk: {
            const frame = get_frame_of_source_content(data, key) orelse break :blk null;
            break :blk frame.line;
        };

        var line_number: i32 = 0;
        if (zgui.beginTabItem(tab_name, .{})) {
            defer zgui.endTabItem();

            var iter = std.mem.splitScalar(u8, content.content, '\n');
            while (iter.next()) |line| {
                const color: [4]f32 = if (active_line == line_number) .{ 1, 0, 0, 1 } else .{ 1, 1, 1, 1 };
                zgui.textColored(color, "{s}", .{line});

                line_number += 1;
            }
        }
    }
}

fn debug_ui(gpas: *const DebugAllocators, callbacks: *Callbacks, connection: *Connection, data: *SessionData, args: Args) !void {
    _ = callbacks;

    if (!state.debug_ui) return;

    try debug_general(gpas, "Debug General", data, connection, args);
    debug_modules("Debug Modules", data.*);
    debug_threads("Debug Threads", data.*, connection);
    debug_stack_frames("Debug Stack Frames", data.*, connection);
    debug_scopes("Debug Scopes", data.*, connection);
    debug_variables("Debug Variables", data.*, connection);
    debug_breakpoints("Debug Breakpoints", data.*, connection);
    debug_sources("Debug Sources", data, connection);
    debug_sources_content("Debug Sources Content", data.*, connection);

    if (state.imgui_demo) zgui.showDemoWindow(&state.imgui_demo);
    if (state.plot_demo) plot.showDemoWindow(&state.plot_demo);
}

fn adapter_capabilities(connection: Connection) void {
    if (connection.state == .not_spawned) return;

    inline for (std.meta.fields(Connection.AdapterCapabilitiesKind)) |field| {
        const contains = connection.adapter_capabilities.support.contains(@enumFromInt(field.value));
        if (contains) {
            zgui.textColored(.{ 0, 1, 0, 1 }, "{s}", .{field.name});
        }
    }

    zgui.separator();

    inline for (std.meta.fields(Connection.AdapterCapabilitiesKind)) |field| {
        const contains = connection.adapter_capabilities.support.contains(@enumFromInt(field.value));
        if (!contains) {
            zgui.textColored(.{ 1, 0, 0, 1 }, "{s}", .{field.name});
        }
    }

    zgui.separator();

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

    if (c.exceptionBreakpointFilters) |value| {
        draw_table_from_slice_of_struct(
            @typeName(protocol.ExceptionBreakpointsFilter),
            protocol.ExceptionBreakpointsFilter,
            value,
        );
    }
    if (c.additionalModuleColumns) |value| {
        draw_table_from_slice_of_struct(
            @typeName(protocol.ColumnDescriptor),
            protocol.ColumnDescriptor,
            value,
        );
    }
    if (c.breakpointModes) |value| {
        draw_table_from_slice_of_struct(
            @typeName(protocol.BreakpointMode),
            protocol.BreakpointMode,
            value,
        );
    }
}

fn manual_requests(connection: *Connection, data: *SessionData, args: Args) !void {
    _ = args;
    const static = struct {
        var name_buf: [512:0]u8 = .{0} ** 512;
        var source_buf: [512:0]u8 = .{0} ** 512;
    };

    draw_launch_configurations(config.launch);

    if (zgui.button("Hide Debug UI", .{})) {
        state.debug_ui = false;
    }
    if (zgui.button("Show Dear ImGui Demo", .{})) {
        state.imgui_demo = true;
    }
    if (zgui.button("Show Plot Demo", .{})) {
        state.plot_demo = true;
    }

    zgui.text("Adapter State: {s}", .{@tagName(connection.state)});
    zgui.text("Debuggee Status: {s}", .{anytype_to_string(data.status, .{ .show_union_name = true })});
    zgui.text("Exit Code:", .{});
    if (data.exit_code) |code| {
        zgui.sameLine(.{});
        zgui.text("{}", .{code});
    }

    if (zgui.button("Begin Debug Sequence", .{})) {
        state.begin_session = true;
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
            .clientName = "glass-dap",
            .adapterID = "???",
            .columnsStartAt1 = false,
            .linesStartAt1 = false,
        };

        try connection.queue_request_init(init_args, .none);
    }

    zgui.sameLine(.{});
    if (zgui.button("Send Launch Request", .{})) {
        request.launch(state.arena(), connection, .{ .dep = .{ .response = .initialize }, .handled_when = .before_queueing }) catch |err| switch (err) {
            error.NoLaunchConfig => state.ask_for_launch_config = true,
            else => log_err(err, @src()),
        };
    }

    zgui.sameLine(.{});
    if (zgui.button("Send configurationDone Request", .{})) {
        _ = try connection.queue_request_configuration_done(null, .{
            .map = .{},
        }, .{ .dep = .{ .event = .initialized }, .handled_when = .before_queueing });
    }

    if (zgui.button("end connection: disconnect", .{})) {
        try request.end_session(connection, .disconnect);
    }

    if (zgui.button("end connection: terminate", .{})) {
        try request.end_session(connection, .terminate);
    }

    if (zgui.button("Modules", .{})) {
        _ = try connection.queue_request(.modules, protocol.ModulesArguments{
            // all modules
            .startModule = null,
            .moduleCount = null,
        }, .none, .no_data);
    }

    if (zgui.button("Threads", .{})) {
        _ = try connection.queue_request(.threads, null, .none, .no_data);
    }

    _ = zgui.inputText("source reference", .{ .buf = &static.source_buf });
    if (zgui.button("Source Content", .{})) blk: {
        const len = std.mem.indexOfScalar(u8, &static.source_buf, 0) orelse static.source_buf.len;
        const id = static.source_buf[0..len];
        const number = std.fmt.parseInt(i32, id, 10) catch break :blk;
        const source = data.sources.get(.{ .reference = number });

        if (source) |s| {
            _ = try connection.queue_request(
                .source,
                protocol.SourceArguments{
                    .source = s.value,
                    .sourceReference = s.value.sourceReference.?,
                },
                .none,
                .{ .source = .{ .path = s.value.path, .source_reference = s.value.sourceReference.? } },
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
    draw_table_from_slice_of_struct(
        "Function Breakpoints",
        protocol.FunctionBreakpoint,
        data.function_breakpoints.items,
    );
}

fn draw_table_from_slice_of_struct(name: [:0]const u8, comptime Type: type, slice: []const Type) void {
    const is_mem_object = @hasDecl(Type, "utils_MemObject");
    const T = if (is_mem_object) Type.ChildType else Type;

    const visiable_name = blk: {
        var iter = std.mem.splitAny(u8, name, "##");
        break :blk iter.next().?;
    };
    zgui.text("{s} len({})", .{ visiable_name, slice.len });
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

        for (slice) |item| {
            const value = if (is_mem_object) item.value else item;
            zgui.tableNextRow(.{});
            inline for (std.meta.fields(@TypeOf(value))) |field| {
                const info = @typeInfo(field.type);
                const field_value = @field(value, field.name);
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

fn format(comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(state.arena(), fmt, args) catch return "OOM";
}

fn anytype_to_string(value: anytype, opts: ToStringOptions) []const u8 {
    return anytype_to_string_recurse(state.arena(), value, opts);
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
        .@"enum" => |info| {
            if (info.fields.len == 0) {
                return std.fmt.allocPrint(allocator, "{s}:{}", .{ @typeName(T), value }) catch unreachable;
            } else {
                return @tagName(value);
            }
        },
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

fn get_frame_of_source_content(data: SessionData, key: SessionData.SourceID) ?protocol.StackFrame {
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;

        for (thread.stack.items) |frame| {
            const source: protocol.Source = frame.value.source orelse continue;
            const eql = switch (key) {
                .path => |path| path.len > 0 and std.mem.eql(u8, source.path orelse "", path),
                .reference => |ref| ref == source.sourceReference,
            };

            if (eql) {
                return frame.value;
            }
        }
    }

    return null;
}

fn get_stack_of_frame(data: *const SessionData, frame: protocol.StackFrame) ?SessionData.Stack {
    for (data.stacks.items) |*stack| {
        if (utils.entry_exists(stack.data, "id", frame.id)) {
            return stack.*;
        }
    }

    return null;
}

fn color_u32(tag: zgui.StyleCol) u32 {
    const color = zgui.getStyle().getColor(tag);
    return zgui.colorConvertFloat4ToU32(color);
}

fn tmp_name(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.allocPrintZ(state.arena(), fmt, args) catch "";
}

fn tmp_shorten_path(path: []const u8) []const u8 {
    const static = struct {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
    };

    const count = std.mem.replace(u8, path, state.home_path.slice(), "~", &static.buf);
    const len = if (count > 0) path.len - state.home_path.len + 1 else path.len;
    return static.buf[0..len];
}

fn thread_of_source(source: protocol.Source, data: SessionData) ?SessionData.Thread {
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;

        for (thread.stack.items) |frame| {
            const s = frame.value.source orelse continue;
            const eql = if (s.path != null and source.path != null)
                std.mem.eql(u8, s.path.?, source.path.?)
            else if (s.sourceReference != null and source.sourceReference != null)
                s.sourceReference.? == source.sourceReference.?
            else
                false;

            if (eql) {
                return thread.*;
            }
        }
    }

    return null;
}

fn draw_launch_configurations(maybe_launch: ?config.Launch) void {
    const launch = maybe_launch orelse return;

    const table = .{
        .{ .name = "Key" },
        .{ .name = "Value" },
    };

    const columns_count = std.meta.fields(@TypeOf(table)).len;

    for (launch.configurations, 0..) |conf, i| {
        const name = tmp_name("Launch Configuration {}", .{i});
        if (zgui.beginTable(name, .{ .column = columns_count, .flags = .{ .resizable = true } })) {
            defer zgui.endTable();
            inline for (table) |entry| zgui.tableSetupColumn(entry.name, .{});
            zgui.tableHeadersRow();

            var iter = conf.map.iterator();
            while (iter.next()) |entry| {
                zgui.tableNextRow(.{});

                _ = zgui.tableNextColumn();
                zgui.text("{s}", .{entry.key_ptr.*});
                _ = zgui.tableNextColumn();
                const value = entry.value_ptr.*;
                if (@TypeOf(value) == std.json.Value and value == .array) {
                    zgui.text("[", .{});
                    for (value.array.items, 0..) |item, ai| {
                        const last = ai + 1 == value.array.items.len;
                        zgui.sameLine(.{});
                        if (!last) {
                            zgui.text("{s},", .{anytype_to_string(item, .{})});
                        } else {
                            zgui.text("{s}", .{anytype_to_string(item, .{})});
                        }
                    }
                    zgui.sameLine(.{});
                    zgui.text("]", .{});
                } else {
                    zgui.text("{s}", .{anytype_to_string(value, .{})});
                }
            }
        }
    }
}

fn pick(name: [:0]const u8, args: anytype, comptime widget: std.meta.Tag(Picker.Widget)) bool {
    if (state.picker == null) {
        state.picker = Picker{};
    }
    // keep the state of the widget alive between frames
    if (std.meta.activeTag(state.picker.?.widget) != widget) {
        state.picker.?.widget = @unionInit(Picker.Widget, @tagName(widget), .{});
    }
    const done = state.picker.?.begin(args, name);
    state.picker.?.end();

    if (done) {
        state.picker = null;
    }
    return done;
}

pub const Picker = struct {
    var window_x: f32 = 0;
    var window_y: f32 = 0;
    var fit_window_in_display = false;

    pub const NextResult = struct {
        size: [2]f32,
        hovered: bool = false,
        clicked: bool = false,
        double_clicked: bool = false,
    };

    pub const Widget = union(enum) {
        none,
        launch_config: LaunchConfig,
    };

    selected_index: usize = 0,

    widget: Widget = .none,

    pub fn begin(picker: *Picker, args: anytype, name: [:0]const u8) bool {
        const display_size = zgui.io.getDisplaySize();
        if (fit_window_in_display) {
            fit_window_in_display = false;
            zgui.setNextWindowSize(.{
                .w = display_size[0],
                .h = display_size[1],
                .cond = .always,
            });
        }
        zgui.setNextWindowPos(.{
            .x = window_x,
            .y = window_y,
            .cond = .always,
        });

        var open = true;
        zgui.openPopup(name, .{});
        const escaped = zgui.isKeyDown(.escape);
        if (!escaped and zgui.beginPopupModal(name, .{ .popen = &open })) {
            defer zgui.endPopup();

            { // center the window
                const window_size = zgui.getWindowSize();
                window_x = (display_size[0] / 2) - (window_size[0] / 2);
                window_y = (display_size[1] / 2) - (window_size[1] / 2);

                if (window_size[0] > display_size[0] or window_size[1] > display_size[1]) {
                    fit_window_in_display = true;
                }
            }

            picker.widget_begin();
            defer picker.widget_end();

            var i: usize = 0;
            while (true) : (i += 1) {
                const start = zgui.getCursorScreenPos();
                const result = picker.widget_next(args) orelse break;

                var color = zgui.getStyle().getColor(.text_selected_bg);
                if (result.clicked) {
                    picker.selected_index = i;
                }

                if (result.double_clicked) {
                    picker.widget_confirm(args, picker.selected_index);
                    return true;
                }

                if (result.hovered) {
                    color[3] = 0.25;
                    zgui.getWindowDrawList().addRectFilled(.{
                        .pmin = start,
                        .pmax = .{ start[0] + result.size[0], start[1] + result.size[1] },
                        .col = zgui.colorConvertFloat4ToU32(color),
                    });
                }

                if (i == picker.selected_index) {
                    color[3] = 0.5;
                    zgui.getWindowDrawList().addRectFilled(.{
                        .pmin = start,
                        .pmax = .{ start[0] + result.size[0], start[1] + result.size[1] },
                        .col = zgui.colorConvertFloat4ToU32(color),
                    });
                }
            }
        } else {
            return true;
        }

        return false;
    }

    pub fn end(_: *Picker) void {}

    pub fn widget_begin(picker: *Picker) void {
        return switch (picker.widget) {
            .none => @panic("Cannot use picker with no widget"),
            inline else => |*widget| widget.begin(),
        };
    }

    pub fn widget_end(picker: *Picker) void {
        return switch (picker.widget) {
            .none => @panic("Cannot use picker with no widget"),
            inline else => |*widget| widget.end(),
        };
    }

    pub fn widget_next(picker: *Picker, args: anytype) ?NextResult {
        return switch (picker.widget) {
            .none => @panic("Cannot use picker with no widget"),
            inline else => |*widget| widget.next(args),
        };
    }

    pub fn widget_confirm(picker: *Picker, args: anytype, index: usize) void {
        return switch (picker.widget) {
            .none => @panic("Cannot use picker with no widget"),
            inline else => |*widget| widget.confirm(args, index),
        };
    }

    pub const LaunchConfig = struct {
        i: usize = 0,
        show_table_for: [512]bool = .{false} ** 512,

        pub fn begin(widget: *LaunchConfig) void {
            zgui.text("Right click to see full configuration", .{});
            widget.i = 0;
        }
        pub fn end(_: *LaunchConfig) void {}

        pub fn next(widget: *LaunchConfig, maybe_launch: ?config.Launch) ?NextResult {
            defer widget.i += 1;
            const launch = maybe_launch orelse return null;
            if (widget.i >= launch.configurations.len) return null;

            const conf = launch.configurations[widget.i];
            if (widget.show_table_for[widget.i]) {
                const name = tmp_name("Launch Configuration {}", .{widget.i});
                return widget.show_table(name, launch);
            } else {
                var name: []const u8 = tmp_name("Launch Configuration {}", .{widget.i});
                if (conf.map.get("name")) |n| if (n == .string) {
                    name = n.string;
                };
                zgui.text("{s}", .{name});
                if (zgui.isItemClicked(.right)) {
                    widget.show_table_for[widget.i] = true;
                }
                return .{
                    .size = zgui.getItemRectSize(),
                    .hovered = zgui.isItemHovered(.{}),
                    .clicked = zgui.isItemClicked(.left),
                    .double_clicked = zgui.isItemClicked(.left) and zgui.isMouseDoubleClicked(.left),
                };
            }

            return null;
        }

        pub fn confirm(_: *LaunchConfig, maybe_launch: ?config.Launch, index: usize) void {
            const launch = maybe_launch orelse return;
            if (index < launch.configurations.len) {
                state.launch_config_index = index;
            }
        }

        pub fn show_table(widget: *LaunchConfig, name: [:0]const u8, launch: config.Launch) ?NextResult {
            const table = .{
                .{ .name = "Key" },
                .{ .name = "Value" },
            };

            const columns_count = std.meta.fields(@TypeOf(table)).len;

            const conf = launch.configurations[widget.i];
            if (zgui.beginTable(name, .{ .column = columns_count, .flags = .{
                .sizing = .fixed_fit,
                .borders = .{ .outer_h = true, .outer_v = true },
            } })) {
                inline for (table) |entry| zgui.tableSetupColumn(entry.name, .{});

                var iter = conf.map.iterator();
                while (iter.next()) |entry| {
                    zgui.tableNextRow(.{});

                    _ = zgui.tableNextColumn();
                    zgui.text("{s}", .{entry.key_ptr.*});
                    _ = zgui.tableNextColumn();
                    const value = entry.value_ptr.*;
                    if (@TypeOf(value) == std.json.Value and value == .array) {
                        zgui.text("[", .{});
                        for (value.array.items, 0..) |item, ai| {
                            const last = ai + 1 == value.array.items.len;
                            zgui.sameLine(.{});
                            if (!last) {
                                zgui.text("{s},", .{anytype_to_string(item, .{})});
                            } else {
                                zgui.text("{s}", .{anytype_to_string(item, .{})});
                            }
                        }
                        zgui.sameLine(.{});
                        zgui.text("]", .{});
                    } else {
                        zgui.text("{s}", .{anytype_to_string(value, .{})});
                    }
                }

                zgui.endTable();
                if (zgui.isItemClicked(.right)) {
                    widget.show_table_for[widget.i] = false;
                }
                return .{
                    .size = zgui.getItemRectSize(),
                    .hovered = zgui.isItemHovered(.{}),
                    .clicked = zgui.isItemClicked(.left),
                    .double_clicked = zgui.isItemClicked(.left) and zgui.isMouseDoubleClicked(.left),
                };
            }

            return null;
        }
    };
};

fn log_err(err: anyerror, src: std.builtin.SourceLocation) void {
    log.err("{} {s}:{}:{} {s}()", .{
        err,
        src.file,
        src.line,
        src.column,
        src.fn_name,
    });
}

fn get_action() ?config.Action {
    const mods = config.Key.Mods.init(.{
        .shift = zgui.isKeyDown(.left_shift) or zgui.isKeyDown(.right_shift),
        .control = zgui.isKeyDown(.left_ctrl) or zgui.isKeyDown(.right_ctrl),
        .alt = zgui.isKeyDown(.left_alt) or zgui.isKeyDown(.right_alt),
    });

    var iter = config.mappings.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const action = entry.value_ptr.*;
        if (zgui.isKeyPressed(key.key, true) and key.mods.eql(mods)) {
            return action;
        }
    }

    return null;
}

fn handle_action(action: config.Action, callbacks: *Callbacks, data: *SessionData, connection: *Connection) !void {
    switch (action) {
        .continue_threads => request.continue_threads(data.*, connection),
        .pause => request.pause(data.*, connection),
        .next_line => request.step(callbacks, data.*, connection, .next, .line),
        .next_statement => request.step(callbacks, data.*, connection, .next, .statement),
        .next_instruction => request.step(callbacks, data.*, connection, .next, .instruction),
        .begin_session => state.begin_session = true,
        .toggle_debug_ui => state.debug_ui = !state.debug_ui,
    }
}

pub const Files = struct {
    allocator: std.mem.Allocator,
    dir: Path = Path.init(0) catch unreachable,
    entries: std.ArrayListUnmanaged(Dir.Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator, dir: []const u8) Files {
        std.debug.assert(fs.path.isAbsolute(dir));
        return .{
            .allocator = allocator,
            .dir = Path.fromSlice(dir) catch unreachable,
        };
    }

    fn deinit(files: *Files) void {
        files.clear();
        files.entries.deinit(files.allocator);
    }

    fn clear(files: *Files) void {
        for (files.entries.items) |entry| files.allocator.free(entry.name);
        files.entries.clearRetainingCapacity();
    }

    fn fill(files: *Files) !void {
        std.debug.assert(files.entries.items.len == 0);

        var dir = try fs.openDirAbsolute(files.dir.slice(), .{ .iterate = true });

        try files.entries.append(files.allocator, .{
            .name = try files.allocator.dupe(u8, ".."),
            .kind = .directory,
        });

        var iter = dir.iterate();
        while (true) {
            const entry = iter.next() catch |err| switch (err) {
                error.AccessDenied,
                error.InvalidUtf8,
                error.Unexpected,
                error.SystemResources,
                => continue,
            } orelse break;

            try files.entries.append(files.allocator, .{
                .name = try files.allocator.dupe(u8, entry.name),
                .kind = entry.kind,
            });
        }
    }

    fn cd(files: *Files, entry: Dir.Entry) !void {
        if (std.mem.eql(u8, entry.name, "..")) {
            const parent = fs.path.dirname(files.dir.slice()) orelse return;
            files.dir = Path.fromSlice(parent) catch unreachable;
        } else {
            files.dir.append(fs.path.sep) catch unreachable;
            files.dir.appendSlice(entry.name) catch unreachable;
        }
        files.clear();
        try files.fill();
    }

    fn open(files: *Files, data: *SessionData, entry: Dir.Entry) !void {
        var path = Path.init(0) catch unreachable;
        path.appendSlice(files.dir.slice()) catch unreachable;
        path.append(fs.path.sep) catch unreachable;
        path.appendSlice(entry.name) catch unreachable;

        try data.set_source(.{ .path = path.slice() });
        // if there's no source we'll get it next frame.
        const source = data.get_source(.{ .path = path.slice() }) orelse return;
        state.active_source.set_source(null, source);
        state.scroll_to_active_line = false;
    }
};

pub const ActiveSource = struct {
    pub const defualt = ActiveSource{
        .thread_id = null,
        .source = .none,
    };

    thread_id: ?SessionData.ThreadID,
    line: ?i32 = null,
    source: union(enum) {
        path: Path,
        reference: i32,
        none,
    },

    pub fn get_id(active: ActiveSource) ?SessionData.SourceID {
        return switch (active.source) {
            .none => null,
            .path => |path| .{ .path = path.slice() },
            .reference => |ref| .{ .reference = ref },
        };
    }

    pub fn get_source_content(active: *ActiveSource, data: *const SessionData) ?struct { SessionData.SourceID, SessionData.SourceContent } {
        const entry = switch (active.source) {
            .none => return null,
            .path => |path| data.sources_content.getEntry(.{ .path = path.slice() }),
            .reference => |ref| data.sources_content.getEntry(.{ .reference = ref }),
        };

        return if (entry) |e|
            .{ e.key_ptr.*, e.value_ptr.* }
        else
            null;
    }

    pub fn set_source_content(active: *ActiveSource, arena: std.mem.Allocator, data: *SessionData, connection: *Connection) !void {
        return switch (active.source) {
            .none => return,
            .path => |path| {
                _, const content = try io.open_file_as_source_content(arena, path.slice());
                try data.set_source_content(.{ .path = path.slice() }, content);
            },
            .reference => |reference| {
                _ = try connection.queue_request(.source, protocol.SourceArguments{
                    .source = null,
                    .sourceReference = reference,
                }, .none, .{
                    .source = .{ .path = null, .source_reference = reference },
                });
            },
        };
    }

    fn set_source(active: *ActiveSource, thread_id: ?SessionData.ThreadID, source: protocol.Source) void {
        if (source.sourceReference) |ref| {
            active.source = .{ .reference = ref };
        } else if (source.path) |path| {
            active.source = .{
                .path = Path.fromSlice(path) catch return,
            };
        }

        active.thread_id = thread_id;
    }

    fn get_thread(active: *ActiveSource, data: *SessionData) ?*SessionData.Thread {
        return data.threads.getPtr(active.thread_id orelse return null) orelse return null;
        // const source_id = state.active_source.id() orelse return null;
        // for (th.stack.items) |frame| {
        //     const source = frame.source orelse continue;
        //     if (utils.source_is(source, source_id)) {
        //         return th;
        //     }
        // }

        // return null;
    }

    fn get_frame(active: *ActiveSource, data: *SessionData) ?protocol.StackFrame {
        const thread = active.get_thread(data) orelse return null;
        const id = active.get_id().?;
        for (thread.stack.items) |frame| {
            const source = frame.value.source orelse continue;
            if (utils.source_is(source, id)) {
                return frame.value;
            }
        }

        return null;
    }
};

pub fn notify(comptime fmt: []const u8, args: anytype, time_ms: isize) void {
    state.notifications.notify(fmt, args, time_ms);
}

pub const Notifications = struct {
    const Message = struct {
        timer: time.Timer,
        time_ms: isize,
        message: []const u8,
    };
    allocator: mem.Allocator,
    messages: std.ArrayListUnmanaged(Message) = .empty,

    pub fn init(allocator: std.mem.Allocator) Notifications {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Notifications) void {
        for (self.messages.items) |item| {
            self.allocator.free(item.message);
        }
        self.messages.deinit(self.allocator);
    }

    pub fn notify(self: *Notifications, comptime fmt: []const u8, args: anytype, time_ms: isize) void {
        const clone = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        errdefer self.allocator.free(clone);
        self.messages.append(self.allocator, .{
            .timer = time.Timer.start() catch unreachable,
            .time_ms = time_ms,
            .message = clone,
        }) catch return;
    }
};

fn breakpoint_in_line(data: *const SessionData, source_id: SessionData.SourceID, line: i32) usize {
    var count: usize = 0;
    for (data.breakpoints.items) |item| {
        const id = switch (item.value.origin) {
            .source => |id| id,
            .event, .function => continue,
        };

        if (source_id.eql(id) and line == item.value.breakpoint.line) {
            count += 1;
        }
    }

    return count;
}

fn breakpoint_toggle(source_id: SessionData.SourceID, line: i32, data: *SessionData, connection: *Connection) void {
    if (breakpoint_in_line(data, source_id, line) > 0) {
        data.remove_source_breakpoint(source_id, line);
    } else {
        data.add_source_breakpoint(source_id, .{
            .line = line,
        }) catch return;
    }

    request.set_breakpoints(data.*, connection, source_id) catch return;
}

////////////////////////////////////////////////////////////////////////////////
// These functions prevent duplicate requests.
// TODO: Detect if a request is not a duplicate and send it.
// As right now they block all requests of the same type

fn request_or_wait_for_variables(connection: *Connection, thread: *const SessionData.Thread, callbacks: *Callbacks, reference: SessionData.VariableReference) void {
    if (state.waiting_for_variables) return;

    request.variables(connection, thread.id, reference) catch return;

    const static = struct {
        fn func(_: *SessionData, _: *Connection, _: ?Connection.RawMessage) void {
            state.waiting_for_variables = false;
        }
    };

    handlers.callback(callbacks, .always, .{ .response = .variables }, null, static.func) catch return;
    state.waiting_for_variables = true;
}

fn request_or_wait_for_stack_trace(connection: *Connection, thread: *const SessionData.Thread, callbacks: *Callbacks) void {
    if (state.waiting_for_stack_trace) return;
    if (thread.state != .stopped) return;

    request.stack_trace(connection, thread.id) catch return;

    const static = struct {
        fn func(_: *SessionData, _: *Connection, _: ?Connection.RawMessage) void {
            state.waiting_for_stack_trace = false;
        }
    };

    handlers.callback(callbacks, .always, .{ .response = .stackTrace }, null, static.func) catch return;
    state.waiting_for_stack_trace = true;
}
