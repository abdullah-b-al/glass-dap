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
const session = @import("session.zig");
const Callbacks = session.Callbacks;
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
const math = std.math;

const Path = std.BoundedArray(u8, std.fs.max_path_bytes);
const String64 = std.BoundedArray(u8, 64);

const SelectedLaunchConfig = struct {
    project: String64,
    index: usize,
};

const State = struct {
    arena_state: std.heap.ArenaAllocator,
    notifications: Notifications,

    render_frames: u8 = 4,
    active_thread: ?SessionData.ThreadID = null,
    active_frame: ?SessionData.FrameID = null,
    active_source: ActiveSource = .defualt,
    icons_solid: zgui.Font = undefined,
    debug_ui: bool = @import("builtin").mode == .Debug,
    plot_demo: bool = false,
    imgui_demo: bool = false,

    files: Files = undefined,
    home_path: Path = Path.init(0) catch unreachable,
    picker: PickerWidget = .none,

    launch_config: ?SelectedLaunchConfig = null,
    adapter_name: String64 = String64.init(0) catch unreachable,

    variable_edit: ?struct {
        reference: SessionData.VariableReference,
        index: usize,
        buffer: [1024:0]u8 = .{0} ** 1024,
    } = null,

    // handled in ui_tick
    ask_for_adapter: bool = false,
    ask_for_launch_config: bool = false,
    begin_session: bool = false,
    update_active_source_to_top_of_stack: bool = false,

    // handled in a widget
    force_open_active_thread: bool = false,

    waiting_for_scopes: bool = false,
    waiting_for_evaluate: bool = false,
    waiting_for_variables: bool = false,
    waiting_for_stack_trace: bool = false,
    waiting_for_loaded_sources: bool = false,

    pub fn arena(s: *State) std.mem.Allocator {
        return s.arena_state.allocator();
    }
};

pub var state = State{
    .arena_state = undefined,
    .notifications = undefined,
};

pub fn continue_rendering() void {
    state.render_frames = 30;
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

pub fn init_ui(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap, cwd: []const u8) !*glfw.Window {
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

    if (state.ask_for_adapter) {
        state.ask_for_adapter = pick(.adapter) == .not_done;
    } else if (state.ask_for_launch_config) {
        state.ask_for_launch_config = pick(.launch_config) == .not_done;
    } else if (state.begin_session) {
        switch (pick(.begin_session)) {
            .cancel => state.begin_session = false,
            .not_done => state.begin_session = true,

            .done => {
                const request_result = request.begin_session(state.arena(), callbacks, connection, data) catch |err| blk: {
                    log_err(err, @src());
                    notify("{}", .{err}, 3000);
                    break :blk .done;
                };

                switch (request_result) {
                    .done => state.begin_session = false,
                    .not_done => {},
                }
            },
        }
    }

    if (state.update_active_source_to_top_of_stack) blk: {
        if (data.threads.getPtr(state.active_thread orelse break :blk)) |thread| {
            if (thread.requested_stack) {
                state.update_active_source_to_top_of_stack = false;
            } else {
                request_or_wait_for_stack_trace(connection, thread, callbacks);
            }
            if (thread.stack.items.len > 0) {
                set_active_frame(thread, @enumFromInt(thread.stack.items[0].value.id));
                const source = thread.stack.items[0].value.source orelse break :blk;
                const new_source_id = SessionData.SourceID.from_source(source) orelse break :blk;
                state.active_source.set_source(new_source_id);

                if (state.active_source.get_id()) |id| {
                    if (!utils.source_is(source, id)) {
                        state.active_source.scroll_to = .active_line;
                    }
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
        var id_threads = zgui.dockBuilderSplitNode(id_source, .right, 0.30, null, &id_source);
        const id_watch = zgui.dockBuilderSplitNode(id_threads, .down, 0.30, null, &id_threads);

        // tabbed, right of Source Code (top right)
        zgui.dockBuilderDockWindow("Threads", id_threads);
        zgui.dockBuilderDockWindow("Sources", id_threads);
        zgui.dockBuilderDockWindow("Breakpoints", id_threads);

        // down threads
        zgui.dockBuilderDockWindow("Watch", id_watch);
        zgui.dockBuilderDockWindow("Variables", id_watch);

        // left of Threads (top left)
        zgui.dockBuilderDockWindow("Source Code", id_source);

        // down source code
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
        zgui.dockBuilderDockWindow("Debug Data Breakpoints Info", id_source);
        zgui.dockBuilderDockWindow("Debug Output", id_source);
        zgui.dockBuilderDockWindow("Debug Step-in Targets", id_source);
        zgui.dockBuilderDockWindow("Debug Goto Targets", id_source);

        zgui.dockBuilderFinish(id_dockspace);

        _ = zgui.DockSpace("Main DockSpace", viewport.getSize(), .{});
    }

    notifications();
    source_code("Source Code", data, connection);
    output("Output", data.*, connection);
    threads("Threads", callbacks, data, connection);
    sources("Sources", callbacks, data, connection);
    variables("Variables", callbacks, data, connection);
    watch("Watch", callbacks, data, connection);
    breakpoints("Breakpoints", data, connection);

    debug_ui(gpas, callbacks, connection, data, argv) catch |err| std.log.err("{}", .{err});

    zgui.backend.draw();

    window.swapBuffers();
}

pub fn thread_has_stopped(thread_id: ?SessionData.ThreadID) void {
    state.active_thread = thread_id;
    state.update_active_source_to_top_of_stack = true;
    state.force_open_active_thread = true;
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
            state.active_source.active_line = int_line;
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

        switch (state.active_source.scroll_to) {
            .active_line => {
                if (active_line) {
                    zgui.setScrollHereY(.{ .center_y_ratio = 0.5 });
                    state.active_source.scroll_to = .none;
                }
            },
            .line => |scroll_to_line| {
                if (scroll_to_line == line_number) {
                    zgui.setScrollHereY(.{ .center_y_ratio = 0.5 });
                    state.active_source.scroll_to = .none;
                }
            },
            .none => {},
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
        }
    }
}

fn sources(name: [:0]const u8, callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
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
                    break; // cd frees the files.entries
                } else {
                    state.files.open(data, entry) catch break :files_blk;
                }
            }
        }
    }

    if (zgui.beginTabItem("Loaded Sources", .{})) {
        defer zgui.endTabItem();

        // only request during suspended state
        for (data.threads.values()) |thread| {
            if (thread.status == .stopped) {
                request_or_wait_for_loaded_sources(connection, data, callbacks);
                break;
            }
        }

        const fn_name = @src().fn_name;
        for (data.sources.values()) |source| {
            const source_path = if (source.value.path) |path| tmp_shorten_path(path) else null;
            const label = if (source_path) |path|
                tmp_name("{s}##" ++ fn_name, .{path})
            else if (source.value.sourceReference) |ref|
                tmp_name("{s}({})##" ++ fn_name, .{ source.value.name orelse "", ref })
            else
                return;

            if (zgui.selectable(label, .{})) blk: {
                const source_id = SessionData.SourceID.from_source(source.value) orelse break :blk;
                state.active_source.set_source(source_id);
                state.active_source.scroll_to = .active_line;
            }
        }
    }
}

fn variables(name: [:0]const u8, callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const thread = data.threads.getPtr(state.active_thread orelse return) orelse return;
    if (thread.status != .stopped) return;

    const frame = state.active_source.get_frame(thread.id, data) orelse return;
    const frame_id: SessionData.FrameID = @enumFromInt(frame.id);
    const scopes = thread.scopes.get(frame_id) orelse {
        request_or_wait_for_scopes(connection, thread, frame_id, callbacks);
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
                variables_node(connection, data, callbacks, thread, "", v, reference, frame_id, i);
            }
        }
    }
}

fn watch(name: [:0]const u8, callbacks: *Callbacks, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const static = struct {
        var buf: [512:0]u8 = .{0} ** 512;
    };

    if (zgui.inputText("##Watch Window Add", .{
        .buf = &static.buf,
        .flags = .{
            .enter_returns_true = true,
        },
    })) {
        const len = std.mem.indexOfScalar(u8, &static.buf, 0) orelse 0;
        const expr = static.buf[0..len];
        data.add_watched_variable(expr) catch return;
        static.buf[0] = 0; // clear
    }

    const thread = data.threads.getPtr(state.active_thread orelse return) orelse return;
    const frame_id = state.active_frame orelse blk: {
        if (thread.stack.items.len == 0) return;
        set_active_frame(thread, @enumFromInt(thread.stack.items[0].value.id));
        break :blk state.active_frame.?;
    };

    for (thread.stack.items, 0..) |item, i| {
        if (item.value.id == @intFromEnum(frame_id)) {
            zgui.text("Frame: {s}[{}]", .{ item.value.name, thread.stack.items.len - i - 1 });
        }
    }

    var to_remove: ?usize = null;
    if (zgui.beginTable("Watch Table", .{
        .column = 2,
        .flags = .{ .resizable = false, .sizing = .fixed_fit },
    })) {
        defer zgui.endTable();
        zgui.tableSetupColumn("##Action", .{ .flags = .{ .width_fixed = true } });
        zgui.tableSetupColumn("##Watch Result", .{ .flags = .{ .width_stretch = true } });
        for (data.watched_variables.items, 0..) |watched, watched_i| {
            zgui.tableNextRow(.{});
            _ = zgui.tableSetColumnIndex(0);
            if (zgui.button(tmp_name("Remove##{s} {}", .{ watched.expression, watched_i }), .{})) {
                to_remove = watched_i;
            }

            _ = zgui.tableSetColumnIndex(1);
            const evaluated = thread.evaluated.get(.{
                .frame_id = frame_id,
                .expression = watched.expression,
            }) orelse {
                request_or_wait_for_evaluate(
                    connection,
                    callbacks,
                    thread.id,
                    frame_id,
                    watched.expression,
                    .watch,
                );
                continue;
            };

            const eval = evaluated.value;
            if (eval.variablesReference > 0) {
                const node_opened = zgui.treeNode(tmp_name("{s}##{} {}", .{ watched.expression, frame_id, watched_i }));
                variable_type(eval.type, true);
                if (!node_opened) continue;
                defer zgui.treePop();

                variables_tree_show_children(callbacks, connection, thread, @enumFromInt(eval.variablesReference));
            } else {
                zgui.text("{s}", .{watched.expression});
                variable_type(eval.type, true);
                zgui.sameLine(.{});
                show_evaluated_result(
                    tmp_name("{s} {}", .{ watched.expression, watched_i }),
                    eval.result,
                );
            }
        }
    }

    if (to_remove) |i| {
        const watched = data.watched_variables.items[i];
        data.remove_watched_variable(watched);
    }
}

fn show_evaluated_result(unique_id: [:0]const u8, result: []const u8) void {
    if (std.mem.count(u8, result, "\n") > 0) {
        const id = tmp_name("{s} {s} {s}", .{ result, unique_id, anytype_to_string(@src(), .{}) });
        _ = zgui.beginChild(id, .{
            .w = zgui.getContentRegionAvail()[0],
            .h = zgui.getTextLineHeightWithSpacing(),

            .child_flags = .{ .border = true, .resize_y = true },
        });
        defer zgui.endChild();
        zgui.text("{s}", .{result});
    } else {
        zgui.text("{s}", .{result});
    }
}

pub fn variable_type(var_type: ?[]const u8, same_line: bool) void {
    const style = zgui.getStyle();
    if (var_type) |t| {
        if (same_line) {
            zgui.sameLine(.{ .spacing = 0 });
        }
        zgui.pushStyleColor4f(.{ .idx = .text, .c = style.getColor(.text_disabled) });
        defer zgui.popStyleColor(.{ .count = 1 });
        zgui.text(": {s}", .{t});
    }
}

fn variables_tree_show_children(
    callbacks: *Callbacks,
    connection: *Connection,
    thread: *const SessionData.Thread,
    reference: SessionData.VariableReference,
) void {
    const vars_mo = thread.variables.get(reference) orelse {
        request_or_wait_for_variables(connection, thread, callbacks, reference);
        return;
    };

    for (vars_mo.value) |v| {
        if (v.variablesReference > 0) {
            const node_opened = zgui.treeNode(tmp_name("{s}##{s}", .{ v.name, anytype_to_string(@src(), .{}) }));
            variable_type(v.type, true);
            if (!node_opened) continue;
            defer zgui.treePop();
            variables_tree_show_children(callbacks, connection, thread, @enumFromInt(v.variablesReference));
        } else {
            zgui.text("{s}", .{v.name});
            variable_type(v.type, true);
            zgui.sameLine(.{});
            zgui.text("{s}", .{v.value});
        }
    }
}

fn variables_node(
    connection: *Connection,
    data: *SessionData,
    callbacks: *Callbacks,
    thread: *const SessionData.Thread,
    parent_variable_name: []const u8,
    variable: protocol.Variable,
    reference: SessionData.VariableReference,
    frame_id: SessionData.FrameID,
    index: usize,
) void {
    const widget: enum { input_text, value, node } =
        if (state.variable_edit != null)
            .input_text
        else if (variable.variablesReference > 0)
            .node
        else
            .value;

    const unique_string = tmp_name("{} {s} {s} {} {} {}", .{
        thread.id,
        parent_variable_name,
        variable.name,
        reference,
        frame_id,
        index,
    });

    widget: switch (widget) {
        .input_text => {
            var edit = &state.variable_edit.?;
            if (edit.index != index or edit.reference != reference) {
                continue :widget .value;
            } else {
                zgui.text("{s}", .{variable.name});
                variable_type(variable.type, true);

                zgui.sameLine(.{});
                zgui.setNextItemWidth(zgui.getContentRegionMax()[0]);
                _ = zgui.inputText(
                    tmp_name("##InputText {s}", .{unique_string}),
                    .{ .buf = &edit.buffer, .flags = .{} },
                );

                if (zgui.isKeyPressed(.enter, false)) {
                    const new_value_len = std.mem.indexOfScalar(u8, &edit.buffer, 0) orelse edit.buffer.len;
                    const new_value = edit.buffer[0..new_value_len];
                    request.set_variable(
                        connection,
                        thread.id,
                        reference,
                        frame_id,
                        parent_variable_name,
                        variable.name,
                        new_value,
                        variable.evaluateName != null,
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
            variable_type(variable.type, true);
            zgui.sameLine(.{});
            zgui.text("{s}", .{variable.value});
        },
        .node => {
            const node_opened = zgui.treeNode(tmp_name("{s}##Node {s}", .{ variable.name, unique_string }));
            variable_type(variable.type, true);

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
                const variable_name = utils.join_variables(
                    state.arena(),
                    parent_variable_name,
                    variable.name,
                ) catch return;

                variables_node(
                    connection,
                    data,
                    callbacks,
                    thread,
                    variable_name,
                    nested,
                    nested_reference,
                    frame_id,
                    i,
                );
            }
        },
    }
}

fn breakpoints(name: [:0]const u8, data: *const SessionData, connection: *Connection) void {
    _ = connection;

    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    for (data.breakpoints.items, 0..) |item, i| {
        const origin = switch (item.value.origin) {
            .event => "event",
            .source => |id| tmp_shorten_path(anytype_to_string(id, .{})),
            .function => "function",
            .data => "data",
        };

        const line = item.value.breakpoint.line orelse continue;
        const n = tmp_name("{s} {?}##{}", .{ origin, line + 1, i });
        if (zgui.selectable(n, .{})) {
            switch (item.value.origin) {
                .source => |id| {
                    state.active_source.set_source(id);
                    state.active_source.scroll_to = .{ .line = line }; // zero based
                },
                else => {},
            }
        }
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
                entry.value_ptr.selected = true;
            }
        }

        zgui.sameLine(.{});
        if (zgui.button("Deselect All", .{})) {
            var iter = data.threads.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.selected = false;
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

    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;

        _ = zgui.checkbox(tmp_name("##Selection {s} {}", .{ thread.name, thread.id }), .{ .v = &thread.selected });
        zgui.sameLine(.{});

        const thread_status = switch (thread.status) {
            .stopped => "Paused",
            .continued => "Continued",
            .unknown => "Unknown",
        };
        zgui.text("{s}", .{thread_status});
        zgui.sameLine(.{});

        const is_active = thread.id == state.active_thread;
        if (is_active and state.force_open_active_thread) {
            state.force_open_active_thread = false;
            zgui.setNextItemOpen(.{ .is_open = true, .cond = .always });
        }
        if (zgui.treeNodeFlags(
            tmp_name("{s} #{}", .{ thread.name, thread.id }),
            .{
                .selected = is_active,
            },
        )) {
            defer zgui.treePop();

            if (!thread.requested_stack) {
                request_or_wait_for_stack_trace(connection, thread, callbacks);
                continue;
            }

            zgui.indent(.{ .indent_w = 1 });

            for (thread.stack.items, 0..) |frame, i| {
                if (zgui.selectable(tmp_name("{s}##{}", .{ frame.value.name, i }), .{})) {
                    set_active_frame(thread, @enumFromInt(frame.value.id));
                    if (frame.value.source) |s| blk: {
                        const id = SessionData.SourceID.from_source(s) orelse break :blk;
                        state.active_source.set_source(id);
                        state.active_source.scroll_to = .active_line;
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
                    _ = connection.queue_request(.stackTrace, args, .{
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
            switch (thread.status) {
                .stopped => |stopped| {
                    zgui.text("{s}", .{anytype_to_string(stopped, .{})});
                },
                else => {
                    zgui.text("{s}", .{anytype_to_string(thread.status, .{})});
                },
            }
        }
    }
}

fn debug_general(gpas: *const DebugAllocators, name: [:0]const u8, callbacks: *Callbacks, data: *SessionData, connection: *Connection, args: Args) !void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Debug Tabs", .{})) return;

    if (zgui.beginTabItem("Memory Usage", .{})) blk: {
        defer zgui.endTabItem();
        continue_rendering();

        zgui.text("Debug Connection: {}", .{connection.debug.enabled});

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
        try manual_requests(callbacks, connection, data, args);
    }

    if (zgui.beginTabItem("Adapter Capabilities", .{})) {
        defer zgui.endTabItem();
        adapter_capabilities(connection.*);
    }

    if (zgui.beginTabItem("Sent Requests", .{})) {
        defer zgui.endTabItem();
        for (connection.debug.requests.items) |item| {
            var buf: [512]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "seq({?}){s}", .{ item.request_seq, @tagName(item.command) }) catch unreachable;
            recursively_draw_protocol_object(state.arena(), slice, slice, .{ .object = item.args });
        }
    }

    const table = .{
        .{ .name = "Queued Messages", .items = connection.messages.items },
        .{ .name = "Debug Handled Responses", .items = connection.debug.handled_responses.items },
        .{ .name = "Debug Failed Messages", .items = connection.debug.failed_messages.items },
        .{ .name = "Debug Handled Events", .items = connection.debug.handled_events.items },
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
        draw_table_from_slice_of_struct(@typeName(Connection.HandledEvent), Connection.HandledEvent, connection.handled_events.items);
    }

    if (zgui.beginTabItem("Queued Requests", .{})) {
        defer zgui.endTabItem();
        draw_table_from_slice_of_struct(@typeName(Connection.Request), Connection.Request, connection.requests.items);
    }

    if (zgui.beginTabItem("Callbacks", .{})) {
        defer zgui.endTabItem();
        draw_table_from_slice_of_struct(@typeName(session.Callback), session.Callback, callbacks.items);
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
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const fields = std.meta.fields(protocol.StackFrame);
    const columns_count = fields.len + 1;
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;

        const n = tmp_name("Thread ID {}##frames slice", .{thread.id});
        if (zgui.beginTable(n, .{ .column = columns_count, .flags = .{ .resizable = true } })) {
            defer zgui.endTable();
            zgui.tableSetupColumn("Actions", .{});
            inline for (fields) |field| {
                zgui.tableSetupColumn(field.name, .{});
            }
            zgui.tableHeadersRow();

            for (thread.stack.items) |item| {
                zgui.tableNextRow(.{});
                _ = zgui.tableSetColumnIndex(0);

                const label = tmp_name("Get Step-in Targets##Thread {} Frame {}", .{ thread.id, item.value.id });
                if (zgui.button(label, .{})) {
                    request.step_in_targets(connection, thread.id, @enumFromInt(item.value.id)) catch return;
                }

                anytype_fill_table(item.value);
            }
        }
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

fn debug_variables(name: [:0]const u8, data: *SessionData, connection: *Connection) void {
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const fields = std.meta.fields(protocol.Variable);
    const columns_count = fields.len + 1;
    if (!zgui.beginTable("Variables Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) return;
    defer zgui.endTable();

    zgui.tableSetupColumn("Action", .{});
    inline for (fields) |field| {
        zgui.tableSetupColumn(field.name, .{});
    }
    zgui.tableHeadersRow();

    for (data.threads.values()) |thread| {
        for (thread.variables.keys(), thread.variables.values()) |ref, vars| {
            for (vars.value, 0..) |v, i| {
                zgui.tableNextRow(.{});
                _ = zgui.tableSetColumnIndex(0);

                evaluate: {
                    const frame_id = frame_id_of_variable(data, thread.id, ref) orelse break :evaluate;
                    if (zgui.button(tmp_name("Evaluate##Button {} {s} {}", .{ ref, v.name, i }), .{})) {
                        const eval_name = v.evaluateName orelse break :evaluate;
                        request.evaluate(
                            connection,
                            thread.id,
                            frame_id,
                            eval_name,
                            .variables,
                        ) catch break :evaluate;
                    }

                    if (thread.evaluated.get(.{ .frame_id = frame_id, .expression = v.evaluateName orelse "" })) |result| {
                        zgui.sameLine(.{});
                        zgui.text("{s}", .{anytype_to_string(result.value.result, .{})});
                    }
                }

                if (zgui.button(tmp_name("Breakpoint Info##Button {} {s} {}", .{ ref, v.name, i }), .{})) blk: {
                    request.data_breakpoint_info_variable(connection, v.name, thread.id, ref) catch break :blk;
                }

                const data_breakpoint: ?protocol.DataBreakpoint = blk: {
                    const mo = data.data_breakpoints_info.get(.{
                        .variable = .{ .reference = ref, .name = v.name },
                    }) orelse break :blk null;
                    const id = switch (mo.value.data.dataId) {
                        .string => |string| string,
                        .null => break :blk null,
                    };

                    break :blk .{
                        .dataId = id,
                        .accessType = null,
                        .condition = null,
                        .hitCondition = null,
                    };
                };

                if (zgui.button(tmp_name("Add Breakpoint##Button {} {s} {}", .{ ref, v.name, i }), .{})) blk: {
                    if (data.add_data_breakpoint(data_breakpoint orelse break :blk) catch break :blk) {
                        request.set_data_breakpoints(data, connection) catch break :blk;
                    }
                }
                if (zgui.button(tmp_name("Remove Breakpoint##Button {} {s} {}", .{ ref, v.name, i }), .{})) blk: {
                    if (data.remove_data_breakpoint(data_breakpoint orelse break :blk)) {
                        request.set_data_breakpoints(data, connection) catch break :blk;
                    }
                }
                if (zgui.button(tmp_name("Remove All Breakpoints##Button {} {s} {}", .{ ref, v.name, i }), .{})) blk: {
                    const bp = data_breakpoint orelse break :blk;
                    if (data.remove_data_breakpoints_of_id(bp.dataId)) {
                        request.set_data_breakpoints(data, connection) catch break :blk;
                    }
                }

                anytype_fill_table(v);
            }
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

    if (zgui.button("Get All Sources", .{})) {
        request.loaded_sources(connection) catch return;
    }

    const columns_count = std.meta.fields(protocol.Source).len + 1;
    var source_to_remove: ?protocol.Source = null;
    if (zgui.beginTable("Source Table", .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        zgui.tableSetupColumn("Actions", .{});
        inline for (std.meta.fields(protocol.Source)) |field| {
            zgui.tableSetupColumn(field.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.sources.values(), 0..) |source, i| {
            const get_content = tmp_name("Get Content##{}", .{i});
            zgui.tableNextRow(.{});
            _ = zgui.tableNextColumn();
            if (zgui.button(get_content, .{})) blk: {
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
                        .{ .source = .{ .path = source.value.path, .source_reference = source.value.sourceReference.? } },
                    ) catch return;
                }
            }

            const static = struct {
                var buf: [32:0]u8 = .{0} ** 32;
            };
            const get_goto = tmp_name("Get Goto Targets##{}", .{i});
            if (zgui.inputText(get_goto, .{
                .buf = &static.buf,
                .flags = .{ .enter_returns_true = true, .chars_decimal = true },
            })) blk: {
                const len = std.mem.indexOfScalar(u8, &static.buf, 0) orelse break :blk;
                const line = std.fmt.parseInt(i32, static.buf[0..len], 10) catch break :blk;
                request.goto_targets(connection, source.value, line) catch return;
            }
            if (zgui.button(tmp_name("Remove Source##{}", .{i}), .{})) {
                source_to_remove = source.value;
            }

            anytype_fill_table(source.value);
        }

        zgui.endTable();

        if (source_to_remove) |source| {
            data.remove_source(source);
        }
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

fn debug_data_breakpoints_info(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const fields = std.meta.fields(SessionData.DataBreakpointInfo.Body);
    const columns_count = fields.len + 1;
    var buf: [64]u8 = undefined;
    const n = std.fmt.bufPrintZ(&buf, "Data Breakpoints Info", .{}) catch return;
    if (zgui.beginTable(n, .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        defer zgui.endTable();
        zgui.tableSetupColumn("ID & Lifetime", .{});
        inline for (fields) |field| {
            zgui.tableSetupColumn(field.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.data_breakpoints_info.keys(), data.data_breakpoints_info.values()) |id, mo| {
            const info = mo.value;
            zgui.tableNextRow(.{});
            _ = zgui.tableNextColumn();
            zgui.text("{s}", .{anytype_to_string(id, .{})});
            zgui.text("{s}", .{anytype_to_string(info.lifetime, .{})});

            anytype_fill_table(info.data);
        }
    }
}

fn debug_output(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const fields = std.meta.fields(SessionData.Output);
    const columns_count = fields.len;
    const n = tmp_name("Output", .{});
    if (zgui.beginTable(n, .{ .column = columns_count, .flags = .{ .resizable = true } })) {
        defer zgui.endTable();
        inline for (fields) |field| {
            zgui.tableSetupColumn(field.name, .{});
        }
        zgui.tableHeadersRow();

        for (data.output.items) |item| {
            zgui.tableNextRow(.{});
            anytype_fill_table(item);
        }
    }
}

fn debug_step_in_targets(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const fields = std.meta.fields(protocol.StepInTarget);
    const columns_count = fields.len;
    for (data.threads.keys(), data.threads.values()) |thread_id, thread| {
        for (thread.step_in_targets.keys(), thread.step_in_targets.values()) |frame_id, targets| {
            const n = tmp_name("Step-in Targets##{} {}", .{ thread_id, frame_id });

            if (zgui.beginTable(n, .{ .column = columns_count, .flags = .{ .resizable = true } })) {
                defer zgui.endTable();
                inline for (fields) |field| {
                    zgui.tableSetupColumn(field.name, .{});
                }
                zgui.tableHeadersRow();

                for (targets.value) |target| {
                    zgui.tableNextRow(.{});
                    anytype_fill_table(target);
                }
            }
        }
    }
}

fn debug_goto_targets(name: [:0]const u8, data: SessionData, connection: *Connection) void {
    _ = connection;
    defer zgui.end();
    if (!zgui.begin(name, .{})) return;

    const fields = std.meta.fields(protocol.GotoTarget);
    const columns_count = fields.len;
    for (data.goto_targets.keys(), data.goto_targets.values()) |source_id, targets| {
        const n = tmp_name("Goto Targets##{}", .{source_id});

        if (zgui.beginTable(n, .{ .column = columns_count, .flags = .{ .resizable = true } })) {
            defer zgui.endTable();
            inline for (fields) |field| {
                zgui.tableSetupColumn(field.name, .{});
            }
            zgui.tableHeadersRow();

            for (targets.value) |target| {
                zgui.tableNextRow(.{});
                anytype_fill_table(target);
            }
        }
    }
}

fn debug_ui(gpas: *const DebugAllocators, callbacks: *Callbacks, connection: *Connection, data: *SessionData, args: Args) !void {
    if (!state.debug_ui) return;

    try debug_general(gpas, "Debug General", callbacks, data, connection, args);
    debug_modules("Debug Modules", data.*);
    debug_threads("Debug Threads", data.*, connection);
    debug_stack_frames("Debug Stack Frames", data.*, connection);
    debug_scopes("Debug Scopes", data.*, connection);
    debug_variables("Debug Variables", data, connection);
    debug_breakpoints("Debug Breakpoints", data.*, connection);
    debug_sources("Debug Sources", data, connection);
    debug_sources_content("Debug Sources Content", data.*, connection);
    debug_data_breakpoints_info("Debug Data Breakpoints Info", data.*, connection);
    debug_output("Debug Output", data.*, connection);
    debug_step_in_targets("Debug Step-in Targets", data.*, connection);
    debug_goto_targets("Debug Goto Targets", data.*, connection);

    if (state.imgui_demo) zgui.showDemoWindow(&state.imgui_demo);
    if (state.plot_demo) plot.showDemoWindow(&state.plot_demo);
}

fn adapter_capabilities(connection: Connection) void {
    if (connection.adapter.state == .not_spawned) return;

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

    {
        const elements = anytype_to_string(c.completionTriggerCharacters orelse &[_][]const u8{""}, .{});
        zgui.text("completionTriggerCharacters {s}", .{elements});
    }

    {
        const elements = anytype_to_string(c.supportedChecksumAlgorithms orelse &[_]protocol.ChecksumAlgorithm{}, .{});
        zgui.text("supportedChecksumAlgorithms {s}", .{elements});
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

fn manual_requests(callbacks: *Callbacks, connection: *Connection, data: *SessionData, args: Args) !void {
    _ = args;
    const static = struct {
        var name_buf: [512:0]u8 = .{0} ** 512;
        var source_buf: [512:0]u8 = .{0} ** 512;
    };

    // draw_launch_configurations(config.configurations);

    if (zgui.button("Hide Debug UI", .{})) {
        state.debug_ui = false;
    }
    if (zgui.button("Show Dear ImGui Demo", .{})) {
        state.imgui_demo = true;
    }
    if (zgui.button("Show Plot Demo", .{})) {
        state.plot_demo = true;
    }

    zgui.text("Adapter State: {s}", .{@tagName(connection.adapter.state)});
    zgui.text("Adapter.Debuggee State: {s}", .{@tagName(connection.adapter.debuggee)});
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
        try connection.adapter.spawn();
    }

    zgui.sameLine(.{});
    if (zgui.button("Initialize Adapter", .{})) {
        try connection.queue_request_init(request.initialize_arguments(connection));
    }

    zgui.sameLine(.{});
    if (zgui.button("Send Launch Request", .{})) {
        request.launch(state.arena(), callbacks, connection) catch |err| switch (err) {
            error.NoLaunchConfig => state.ask_for_launch_config = true,
            else => log_err(err, @src()),
        };
    }

    zgui.sameLine(.{});
    if (zgui.button("Send configurationDone Request", .{})) {
        _ = try connection.queue_request_configuration_done(null, .{ .map = .{} });
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
        }, .no_data);
    }

    if (zgui.button("Threads", .{})) {
        _ = try connection.queue_request(.threads, null, .no_data);
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
                if (info == .pointer and info.pointer.size == .slice) {
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

fn anytype_fill_table(value: anytype) void {
    inline for (meta.fields(@TypeOf(value))) |field| {
        _ = zgui.tableNextColumn();
        zgui.text("{s}", .{anytype_to_string(@field(value, field.name), .{})});
    }
}

fn anytype_to_string_recurse(allocator: std.mem.Allocator, const_value: anytype, opts: ToStringOptions) []const u8 {
    const Type = @TypeOf(const_value);
    const is_mem_object = switch (@typeInfo(Type)) {
        .@"enum", .@"struct", .@"union" => @hasDecl(Type, "utils_MemObject"),
        else => false,
    };
    const T = if (is_mem_object) Type.ChildType else Type;
    const value = if (is_mem_object) @field(const_value, "value") else const_value;
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
        .pointer => |info| {
            switch (info.size) {
                .one, .many, .c => return @typeName(T),
                .slice => {
                    var list = std.ArrayList(u8).init(allocator);
                    var writer = list.writer();
                    writer.print("[ ", .{}) catch unreachable;
                    for (value, 0..) |v, i| {
                        const str = anytype_to_string_recurse(allocator, v, opts);
                        if (i + 1 == value.len) {
                            writer.print("{s}", .{str}) catch unreachable;
                        } else {
                            writer.print("{s}, ", .{str}) catch unreachable;
                        }
                    }
                    writer.print(" ]", .{}) catch unreachable;

                    return list.items;
                },
            }
            return @typeName(T);
        },
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

fn draw_launch_configurations(maybe_launch: ?config.Object) void {
    const launch = maybe_launch orelse return;

    const table = .{
        .{ .name = "Key" },
        .{ .name = "Value" },
    };

    const columns_count = std.meta.fields(@TypeOf(table)).len;

    for (launch, 0..) |conf, i| {
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

fn pick(comptime widget: std.meta.Tag(PickerWidget)) picker.PickResult {

    // keep the state of the widget alive between frames
    if (std.meta.activeTag(state.picker) != widget) {
        state.picker = @unionInit(PickerWidget, @tagName(widget), .{});
    }
    const result = state.picker.pick();
    switch (result) {
        .done => {
            state.picker.done();
            state.picker = .none;
        },
        .cancel => {
            state.picker = .none;
        },
        .not_done => {},
    }

    return result;
}

pub const PickerWidget = union(enum) {
    none,
    launch_config: PickerLaunchConfig,
    adapter: PickerAdapter,
    begin_session: PickerBeginSession,

    pub fn pick(widget: *PickerWidget) picker.PickResult {
        return switch (widget.*) {
            .none => .done,
            inline else => |*w| w.pick(),
        };
    }

    pub fn done(widget: *PickerWidget) void {
        switch (widget.*) {
            .none => {},
            inline else => |*w| w.done(),
        }
    }
};

pub const picker = struct {
    var window_x: f32 = 0;
    var window_y: f32 = 0;
    var fit_window_in_display = false;

    pub const EntryResult = struct {
        pub const none = EntryResult{
            .start_pos = .{ 0, 0 },
            .size = .{ 0, 0 },
            .hovered = false,
            .clicked = false,
            .double_clicked = false,
        };

        start_pos: [2]f32,
        size: [2]f32,
        hovered: bool = false,
        clicked: bool = false,
        double_clicked: bool = false,

        pub fn hightlight(result: EntryResult, color: [4]f32) void {
            zgui.getWindowDrawList().addRectFilled(.{
                .pmin = result.start_pos,
                .pmax = .{ result.start_pos[0] + result.size[0], result.start_pos[1] + result.size[1] },
                .col = zgui.colorConvertFloat4ToU32(color),
            });
        }
    };

    pub const PickResult = enum {
        done,
        cancel,
        not_done,
    };

    pub fn begin_window(name: [:0]const u8) bool {
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
            { // center the window
                const window_size = zgui.getWindowSize();
                window_x = (display_size[0] / 2) - (window_size[0] / 2);
                window_y = (display_size[1] / 2) - (window_size[1] / 2);

                if (window_size[0] > display_size[0] or window_size[1] > display_size[1]) {
                    fit_window_in_display = true;
                }
            }

            return true;
        }

        return false;
    }

    pub fn end_window() void {
        zgui.endPopup();
    }
};

pub const PickerAdapter = struct {
    pub fn pick(_: *PickerAdapter) picker.PickResult {
        if (!picker.begin_window("Pick Adapter")) {
            return .cancel;
        }
        defer picker.end_window();

        for (config.app.adapters.keys(), config.app.adapters.values()) |name, entries| {
            const cmd = blk: {
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, "command")) {
                        switch (entry.value) {
                            .string_array => |array| break :blk array,
                            else => zgui.text("{s}: has a non-string_array command", .{name}),
                        }
                    }
                }

                zgui.text("{s}: Doesn't have a command entry", .{name});
                continue;
            };

            const id_exists = blk: {
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, "id")) {
                        switch (entry.value) {
                            .string => break :blk true,
                            else => zgui.text("{s}: has a non-string id", .{name}),
                        }
                    }
                }
                break :blk false;
            };

            if (!id_exists) {
                zgui.text("{s}: Doesn't have an id entry", .{name});
                continue;
            }

            if (zgui.selectable(tmp_name("{s}: {s}", .{ name, cmd }), .{})) {
                state.adapter_name = String64.fromSlice(name) catch {
                    notify("Adapter command too long: {s}", .{name}, 3000);
                    return .not_done;
                };

                return .done;
            }
        }

        return .not_done;
    }

    pub fn done(_: *PickerAdapter) void {}
};

pub const PickerLaunchConfig = struct {
    const size = 512;
    var buffer: [size]u8 = undefined;
    var fb_allocator = std.heap.FixedBufferAllocator.init(&buffer);
    show_table_for: std.AutoArrayHashMapUnmanaged(u32, void) = .empty,
    hash_of_selected: u32 = 0,

    pub fn pick(widget: *PickerLaunchConfig) picker.PickResult {
        if (!picker.begin_window("Pick Launch configuration")) return .cancel;
        defer picker.end_window();

        defer zgui.endTabBar();
        if (!zgui.beginTabBar("PickerLaunchConfig Tab Bar", .{})) return .cancel;

        for (config.app.projects.keys(), config.app.projects.values()) |project_name, configs| {
            if (zgui.beginTabItem(tmp_name("{s}##{s}", .{ project_name, @typeName(PickerLaunchConfig) }), .{})) {
                defer zgui.endTabItem();
                zgui.text("Right click to see full configuration", .{});

                for (configs.items, 0..) |conf, i| {
                    var hasher = std.hash.Wyhash.init(0);
                    std.hash.autoHashStrat(&hasher, project_name, .Deep);
                    std.hash.autoHashStrat(&hasher, i, .Deep);
                    const hash = @as(u32, @truncate(hasher.final()));

                    const result = widget.show_config(hash, conf);
                    if (widget.handle(result, hash, project_name, i)) {
                        return .done;
                    }
                }
            }
        }

        return .not_done;
    }

    pub fn done(_: *PickerLaunchConfig) void {
        fb_allocator.reset();
    }

    fn handle(widget: *PickerLaunchConfig, result: picker.EntryResult, hash: u32, project_name: []const u8, config_index: usize) bool {
        var color = zgui.getStyle().getColor(.text_selected_bg);
        if (result.clicked) {
            widget.hash_of_selected = hash;
        }

        if (result.hovered) {
            color[3] = 0.25;
            result.hightlight(color);
        }

        if (hash == widget.hash_of_selected) {
            color[3] = 0.5;
            result.hightlight(color);
        }

        if (result.double_clicked) {
            widget.confirm(project_name, config_index);
            return true;
        } else {
            return false;
        }
    }

    pub fn show_config(widget: *PickerLaunchConfig, hash: u32, conf: config.Object) picker.EntryResult {
        const start_pos = zgui.getCursorScreenPos();
        if (widget.show_table_for.contains(hash)) {
            const name = tmp_name("Launch Configuration {}", .{hash});
            return widget.show_table(name, hash, conf);
        } else {
            var name: []const u8 = tmp_name("Launch Configuration {}", .{hash});
            if (conf.map.get("name")) |n| if (n == .string) {
                name = n.string;
            };
            zgui.text("{s}", .{name});
            if (zgui.isItemClicked(.right)) {
                widget.show_table_for.put(fb_allocator.allocator(), hash, {}) catch log.err("OOM", .{});
            }
            return .{
                .start_pos = start_pos,
                .size = zgui.getItemRectSize(),
                .hovered = zgui.isItemHovered(.{}),
                .clicked = zgui.isItemClicked(.left),
                .double_clicked = zgui.isItemClicked(.left) and zgui.isMouseDoubleClicked(.left),
            };
        }
    }

    pub fn confirm(_: *PickerLaunchConfig, project_name: []const u8, config_index: usize) void {
        const name = String64.fromSlice(project_name) catch {
            notify("Project name is too long: {s}", .{project_name}, 3000);
            return;
        };

        state.launch_config = .{ .project = name, .index = config_index };
    }

    pub fn show_table(widget: *PickerLaunchConfig, name: [:0]const u8, hash: u32, conf: config.Object) picker.EntryResult {
        const table = .{
            .{ .name = "Key" },
            .{ .name = "Value" },
        };

        const columns_count = std.meta.fields(@TypeOf(table)).len;

        const start_pos = zgui.getCursorScreenPos();
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
                _ = widget.show_table_for.swapRemove(hash);
            }
            return .{
                .start_pos = start_pos,
                .size = zgui.getItemRectSize(),
                .hovered = zgui.isItemHovered(.{}),
                .clicked = zgui.isItemClicked(.left),
                .double_clicked = zgui.isItemClicked(.left) and zgui.isMouseDoubleClicked(.left),
            };
        }

        return .none;
    }
};

pub const PickerBeginSession = struct {
    var adapter: PickerAdapter = .{};
    var launch_config: PickerLaunchConfig = .{};
    pub fn pick(_: *PickerBeginSession) picker.PickResult {
        if (state.adapter_name.len == 0) {
            switch (adapter.pick()) {
                .not_done, .cancel => |v| return v,
                .done => {},
            }
        }

        if (state.launch_config == null) {
            switch (launch_config.pick()) {
                .not_done, .cancel => |v| return v,
                .done => return .done,
            }
        }

        return .done;
    }

    pub fn done(_: *PickerBeginSession) void {}
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

    for (config.app.mappings.keys(), config.app.mappings.values()) |key, action| {
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
        .begin_session => state.begin_session = true,
        .toggle_debug_ui => state.debug_ui = !state.debug_ui,

        .next_line => request.step(callbacks, data.*, connection, .next, .line),
        .next_statement => request.step(callbacks, data.*, connection, .next, .statement),
        .next_instruction => request.step(callbacks, data.*, connection, .next, .instruction),

        .step_in_line => request.step(callbacks, data.*, connection, .in, .line),
        .step_in_statement => request.step(callbacks, data.*, connection, .in, .statement),
        .step_in_instruction => request.step(callbacks, data.*, connection, .in, .instruction),

        .step_out_line => request.step(callbacks, data.*, connection, .out, .line),
        .step_out_statement => request.step(callbacks, data.*, connection, .out, .statement),
        .step_out_instruction => request.step(callbacks, data.*, connection, .out, .instruction),
    }
}

fn set_active_frame(thread: *const SessionData.Thread, frame_id: SessionData.FrameID) void {
    state.active_thread = thread.id;
    state.active_frame = frame_id;

    for (thread.stack.items) |frame| {
        if (frame.value.id == @intFromEnum(frame_id)) {
            return;
        }
    }

    @panic("active_frame doesn't exist in thread");
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
        state.active_source.set_source(.{ .path = path.slice() });
    }
};

pub const ActiveSource = struct {
    pub const defualt = ActiveSource{
        .source = .none,
        .scroll_to = .none,
    };

    active_line: ?i32 = null,
    source: union(enum) {
        path: Path,
        reference: i32,
        none,
    },

    scroll_to: union(enum) {
        active_line,
        line: i32,
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

    /// Request the adapter for content or read a file
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
                }, .{
                    .source = .{ .path = null, .source_reference = reference },
                });
            },
        };
    }

    fn set_source(active: *ActiveSource, source_id: SessionData.SourceID) void {
        active.source = switch (source_id) {
            .reference => |ref| .{ .reference = ref },
            .path => |path| .{ .path = Path.fromSlice(path) catch return },
        };
    }

    fn get_frame(active: *ActiveSource, thread_id: SessionData.ThreadID, data: *SessionData) ?protocol.StackFrame {
        const thread = data.threads.getPtr(thread_id) orelse return null;
        const id = active.get_id() orelse return null;
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
            .data, .event, .function => continue,
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

fn frame_id_of_variable(data: *const SessionData, thread_id: SessionData.ThreadID, reference: SessionData.VariableReference) ?SessionData.FrameID {
    var thread = data.threads.get(thread_id).?;

    for (thread.scopes.keys(), thread.scopes.values()) |frame_id, scopes_mo| {
        for (scopes_mo.value) |scope| {
            if (scope.variablesReference == @intFromEnum(reference)) {
                return frame_id;
            }
        }
    }

    return null;
}

////////////////////////////////////////////////////////////////////////////////
// These functions prevent duplicate requests.
// TODO: Detect if a request is not a duplicate and send it.
// As right now they block all requests of the same type

fn request_or_wait_for_variables(connection: *Connection, thread: *const SessionData.Thread, callbacks: *Callbacks, reference: SessionData.VariableReference) void {
    std.debug.assert(@intFromEnum(reference) > 0);
    if (state.waiting_for_variables) return;

    request.variables(connection, thread.id, reference) catch return;

    const static = struct {
        fn func(_: *SessionData, _: *Connection) void {
            state.waiting_for_variables = false;
        }
    };

    session.callback(callbacks, .always, .{ .response = .variables }, static.func) catch return;
    state.waiting_for_variables = true;
}

fn request_or_wait_for_scopes(
    connection: *Connection,
    thread: *const SessionData.Thread,
    frame_id: SessionData.FrameID,
    callbacks: *Callbacks,
) void {
    if (state.waiting_for_scopes) return;

    request.scopes(connection, thread.id, frame_id, false) catch return;

    const static = struct {
        fn func(_: *SessionData, _: *Connection) void {
            state.waiting_for_scopes = false;
        }
    };

    session.callback(callbacks, .always, .{ .response = .scopes }, static.func) catch return;
    state.waiting_for_scopes = true;
}

fn request_or_wait_for_stack_trace(connection: *Connection, thread: *const SessionData.Thread, callbacks: *Callbacks) void {
    if (state.waiting_for_stack_trace) return;
    if (thread.status != .stopped) return;

    request.stack_trace(connection, thread.id) catch return;

    const static = struct {
        fn func(_: *SessionData, _: *Connection) void {
            state.waiting_for_stack_trace = false;
        }
    };

    session.callback(callbacks, .always, .{ .response = .stackTrace }, static.func) catch return;
    state.waiting_for_stack_trace = true;
}

fn request_or_wait_for_loaded_sources(connection: *Connection, data: *const SessionData, callbacks: *Callbacks) void {
    if (!connection.adapter_capabilities.supports(.supportsLoadedSourcesRequest))
        return;

    if (connection.adapter.state != .initialized) return;
    if (state.waiting_for_loaded_sources) return;
    if (data.loaded_sources_count > 0) return;

    request.loaded_sources(connection) catch |err| switch (err) {
        error.OutOfMemory,
        error.AdapterNotSpawned,
        error.AdapterNotDoneInitializing,
        => {},

        error.AdapterDoesNotSupportRequest => unreachable,
    };

    const static = struct {
        fn func(_: *SessionData, _: *Connection) void {
            state.waiting_for_loaded_sources = false;
        }
    };

    session.callback(callbacks, .always, .{ .response = .loadedSources }, static.func) catch return;
    state.waiting_for_loaded_sources = true;
}

fn request_or_wait_for_evaluate(connection: *Connection, callbacks: *Callbacks, thread_id: SessionData.ThreadID, frame_id: SessionData.FrameID, expression: []const u8, context: request.EvaluateContext) void {
    if (state.waiting_for_evaluate) return;

    request.evaluate(connection, thread_id, frame_id, expression, context) catch return;

    const static = struct {
        fn func(_: *SessionData, _: *Connection) void {
            state.waiting_for_evaluate = false;
        }
    };

    session.callback(callbacks, .always, .{ .response = .evaluate }, static.func) catch return;
    state.waiting_for_evaluate = true;
}
