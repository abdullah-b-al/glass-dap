const std = @import("std");
const glfw = @import("zglfw");
const protocol = @import("protocol.zig");
const io = @import("io.zig");
const utils = @import("utils.zig");
const Connection = @import("connection.zig");
const SessionData = @import("session_data.zig");
const Object = protocol.Object;
const time = std.time;
const ui = @import("ui.zig");
const log = std.log.scoped(.main);
const handlers = @import("handlers.zig");
const config = @import("config.zig");
const mem = std.mem;

pub const GPA = std.heap.GeneralPurposeAllocator(.{
    .enable_memory_limit = true,
});

pub const DebugAllocators = struct {
    const Snapshot = struct {
        index: f64,
        memory: f64,
    };

    pub const Allocator = struct {
        gpa: GPA = .init,
        snapshots: std.MultiArrayList(Snapshot) = .empty,

        pub fn deinit(self: *Allocator) void {
            self.snapshots.deinit(self.allocator());
            _ = self.gpa.deinit();
        }

        pub fn allocator(self: *Allocator) mem.Allocator {
            return self.gpa.allocator();
        }

        pub fn snap(self: *Allocator) !void {
            const bytes = self.gpa.total_requested_bytes;
            if (@TypeOf(bytes) != void) {
                const index: f64 = @floatFromInt(self.snapshots.len);
                const memory: f64 = @floatFromInt(bytes);
                const snapshot = Snapshot{
                    .index = index,
                    .memory = memory / 1024 / 1024, // MiB
                };
                try self.snapshots.append(self.allocator(), snapshot);
            }
        }
    };

    general: Allocator,
    connection: Allocator,
    session_data: Allocator,
    ui: Allocator,
    timer: time.Timer,
    interval_seconds: u16,
};

pub fn main() !void {
    const args = try parse_args();
    var gpas = DebugAllocators{
        .general = .{},
        .connection = .{},
        .session_data = .{},
        .ui = .{},
        .timer = try time.Timer.start(),
        .interval_seconds = 1,
    };
    defer {
        gpas.general.deinit();
        gpas.connection.deinit();
        gpas.session_data.deinit();
        gpas.ui.deinit();
    }

    if (args.cwd.len > 0) {
        const dir = if (std.fs.path.isAbsolute(args.cwd))
            try std.fs.openDirAbsolute(args.cwd, .{})
        else
            try std.fs.cwd().openDir(args.cwd, .{});

        try dir.setAsCwd();
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);

    // set configurations

    // launch json
    const file = try config.find_launch_json();
    const launch = if (file) |path| try config.open_and_parse_launch_json(gpas.general.allocator(), path) else null;
    defer if (launch) |l| l.deinit();
    if (launch) |l| {
        config.launch = l.value;
    }

    // key mappings
    try set_mappings(gpas.general.allocator());
    defer config.mappings.deinit(gpas.general.allocator());

    const window = try ui.init_ui(gpas.ui.allocator(), cwd);
    defer ui.deinit_ui(window);

    var data = SessionData.init(gpas.session_data.allocator());
    defer data.deinit();

    const adapter: []const []const u8 = &.{args.adapter};
    var connection = Connection.init(gpas.connection.allocator(), adapter, args.debug_connection);
    defer connection.deinit();

    var callbacks = handlers.Callbacks.init(gpas.connection.allocator());
    defer {
        for (callbacks.items) |cb| {
            if (cb.message) |m| m.deinit();
        }
        callbacks.deinit();
    }

    loop(&gpas, window, &callbacks, &connection, &data, args);

    log.info("Window Closed", .{});
}

fn loop(gpas: *DebugAllocators, window: *glfw.Window, callbacks: *handlers.Callbacks, connection: *Connection, data: *SessionData, args: Args) void {
    gpas.timer.reset();

    var ui_arena = std.heap.ArenaAllocator.init(gpas.ui.allocator());
    defer ui_arena.deinit();
    while (!window.shouldClose()) {
        while (true) {
            const ok = connection.queue_messages(1) catch |err| blk: {
                log.err("queue_messages: {}", .{err});
                break :blk false;
            };
            if (!ok) break;
        }

        handlers.send_queued_requests(connection);
        const handled_message = handlers.handle_queued_messages(callbacks, data, connection);
        handlers.handle_callbacks(callbacks, data, connection);

        if (handled_message) {
            ui.continue_rendering();
        }
        ui.ui_tick(gpas, &ui_arena, window, callbacks, connection, data, args);
    }
}

pub const Args = struct {
    adapter: []const u8 = "",
    cwd: []const u8 = "",
    debug_connection: bool = false,
};
fn parse_args() !Args {
    if (std.os.argv.len == 1) {
        log.err("Must provide arguments", .{});
        std.process.exit(1);
    }

    var iter = std.process.ArgIterator.init();
    var result = Args{};
    _ = iter.skip();
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--adapter")) {
            result.adapter = try get_arg_without_double_dash(&iter, error.MissingAdapterPath);
        } else if (std.mem.eql(u8, arg, "--cwd")) {
            result.cwd = try get_arg_without_double_dash(&iter, error.MissingCurrentWorkingDirectory);
        } else if (std.mem.eql(u8, arg, "--debug_connection")) {
            result.debug_connection = true;
        } else {
            log.err("Unknow arg {s}", .{arg});
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

fn set_mappings(allocator: std.mem.Allocator) !void {
    const mods = config.Key.Mods.init;
    const m = &config.mappings;

    config.mappings = .empty;
    try config.mappings.ensureTotalCapacity(allocator, 512);

    m.putAssumeCapacity(
        .{ .mods = mods(.{ .control = true }), .key = .l },
        .next_line,
    );
    m.putAssumeCapacity(
        .{ .mods = mods(.{ .control = true }), .key = .s },
        .next_statement,
    );
    m.putAssumeCapacity(
        .{ .mods = mods(.{ .control = true }), .key = .i },
        .next_instruction,
    );
    m.putAssumeCapacity(
        .{ .mods = mods(.{ .control = true }), .key = .p },
        .pause,
    );
    m.putAssumeCapacity(
        .{ .mods = mods(.{ .control = true }), .key = .c },
        .continue_threads,
    );
    m.putAssumeCapacity(
        .{ .mods = mods(.{ .control = true }), .key = .b },
        .begin_session,
    );
}
