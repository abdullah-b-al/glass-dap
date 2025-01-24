const std = @import("std");
const zgui = @import("zgui");
const glfw = @import("zglfw");
const zopengl = @import("zopengl");
const protocol = @import("protocol.zig");
const io = @import("io.zig");
const utils = @import("utils.zig");
const Session = @import("session.zig");
const Object = protocol.Object;
const time = std.time;

pub fn main() !void {
    const args = try parse_args();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    const window = try init_ui(gpa.allocator());
    defer deinit_ui(window);

    const adapter: []const []const u8 = &.{args.adapter};
    var session = Session.init(gpa.allocator(), adapter);

    try session.adapter_spawn();
    try begin_debug_sequence(&session, args);

    while (!window.shouldClose()) {
        session.queue_messages(1) catch |err| {
            std.debug.print("{}\n", .{err});
        };

        ui_tick(window, &session) catch |err| {
            std.log.err("ui_tick:{}", .{err});
        };
    }
    std.log.info("Window Closed", .{});
}

fn begin_debug_sequence(session: *Session, args: Args) !void {
    const init_args = protocol.InitializeRequestArguments{
        .clientName = "unidep",
        .adapterID = "???",
    };
    const init_seq = try session.send_init_request(init_args, .{});
    try session.wait_for_response(init_seq);
    try session.handle_init_response(init_seq);

    var extra = Object{};
    defer extra.deinit(session.allocator);
    try extra.map.put(session.allocator, "program", .{ .string = args.debugee });

    const launch_seq = try session.send_launch_request(.{}, extra);
    try session.wait_for_event("initialized");
    try session.handle_initialized_event();

    // TODO: Send configurations here

    const config_seq = try session.send_configuration_done_request(null, .{});

    try session.wait_for_response(launch_seq);
    try session.handle_launch_response(launch_seq);
    try session.wait_for_response(config_seq);
    try session.handle_configuration_done_response(config_seq);
}

fn init_ui(allocator: std.mem.Allocator) !*glfw.Window {
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

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor @max(scale[0], scale[1]);
    };

    _ = zgui.io.addFontFromFile(
        "/home/ab55al/.local/share/fonts/JetBrainsMono-Regular.ttf",
        std.math.floor(32.0 * scale_factor),
    );

    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);

    return window;
}

fn deinit_ui(window: *glfw.Window) void {
    zgui.backend.deinit();
    zgui.deinit();
    window.destroy();
    glfw.terminate();
}

fn ui_tick(window: *glfw.Window, session: *Session) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const gl = zopengl.bindings;
    glfw.pollEvents();

    gl.clearBufferfv(gl.COLOR, 0, &[_]f32{ 0, 0, 0, 1.0 });

    const fb_size = window.getFramebufferSize();

    zgui.backend.newFrame(@intCast(fb_size[0]), @intCast(fb_size[1]));

    // Set the starting window position and size to custom values
    zgui.setNextWindowPos(.{ .x = 20.0, .y = 20.0, .cond = .first_use_ever });
    zgui.setNextWindowSize(.{ .w = -1.0, .h = -1.0, .cond = .first_use_ever });

    const err = debug_ui(arena.allocator(), session);

    zgui.backend.draw();

    window.swapBuffers();

    return err;
}

fn debug_ui(arena: std.mem.Allocator, session: *Session) !void {
    const table = .{
        .{ .name = "Queued Responses", .items = session.responses.items },
        .{ .name = "Handled Responses", .items = session.handled_responses.items },
        .{ .name = "Events", .items = session.events.items },
        .{ .name = "Handled Events", .items = session.handled_events.items },
    };

    var open: bool = true;
    zgui.showDemoWindow(&open);

    defer zgui.end();
    if (!zgui.begin("Debug", .{})) return;

    defer zgui.endTabBar();
    if (!zgui.beginTabBar("Debug Tabs", .{})) return;

    if (zgui.beginTabItem("Manully Send Requests", .{})) {
        defer zgui.endTabItem();

        if (zgui.button("end session: disconnect", .{})) {
            const seq = try session.end_session(.disconnect);
            try session.wait_for_response(seq);
            try session.handle_disconnect_response(seq);
        }

        if (zgui.button("end session: terminate", .{})) {
            _ = try session.end_session(.terminate);
        }

        session.handle_terminated_event() catch |err| switch (err) {
            error.EventDoseNotExist => {},
            // else => |e| std.log.err("debug_ui:{}", .{e}),
        };
    }

    if (zgui.beginTabItem("Adapter Capabilities", .{})) {
        defer zgui.endTabItem();
        var iter = session.adapter_capabilities.support.iterator();
        while (iter.next()) |e| {
            const name = @tagName(e);
            var color = [4]f32{ 1, 1, 1, 1 };
            if (std.mem.endsWith(u8, name, "Request")) {
                color = .{ 0, 0, 1, 1 };
            }
            zgui.textColored(color, "{s}", .{name});
        }
    }

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

    if (zgui.beginTabItem("Console Output", .{})) {
        defer zgui.endTabItem();
        while (true) {
            session.handle_output_event() catch break;
        }
        for (session.handled_events.items) |item| {
            const output = utils.get_value(item.value, "body.output", .string) orelse continue;
            zgui.text("{s}", .{output});
        }
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

const Args = struct {
    adapter: []const u8 = "",
    debugee: []const u8 = "",
};
fn parse_args() !Args {
    if (std.os.argv.len == 1) {
        std.log.err("Must provide arguments", .{});
        std.process.exit(1);
    }

    var iter = std.process.ArgIterator.init();
    var result = Args{};
    _ = iter.skip();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--adapter")) {
            result.adapter = try get_arg_without_double_dash(&iter, error.MissingAdapterPath);
        } else if (std.mem.eql(u8, arg, "--debugee")) {
            result.debugee = try get_arg_without_double_dash(&iter, error.MissingDebugeePath);
        } else {
            std.log.err("Unknow arg {s}", .{arg});
            std.process.exit(1);
        }
    }

    return result;
}

fn get_arg_without_double_dash(iter: *std.process.ArgIterator, err: anyerror) ![]const u8 {
    const arg = iter.next() orelse return err;
    if (std.mem.startsWith(u8, arg, "--")) {
        return err;
    }

    return arg;
}
