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
const session = @import("session.zig");
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

    var env_map = try std.process.getEnvMap(gpas.general.allocator());
    defer env_map.deinit();

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);

    // set configurations
    defer config.app.deinit();

    const config_file = config.open_config_file(gpas.general.allocator()) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (config_file) |file| file.close();

    if (config_file) |file| {
        const content = try file.readToEndAlloc(gpas.general.allocator(), std.math.maxInt(u32));
        defer gpas.general.allocator().free(content);
        config.app = try config.parse_config(gpas.general.allocator(), content);
    }

    const window = try ui.init_ui(gpas.ui.allocator(), &env_map, cwd);
    defer ui.deinit_ui(window);

    var data = SessionData.init(gpas.session_data.allocator());
    defer data.deinit();

    var connection = Connection.init(gpas.connection.allocator(), args.debug_connection);
    defer connection.deinit();

    var callbacks = session.Callbacks.init(gpas.connection.allocator());
    defer {
        for (callbacks.items) |cb| {
            if (cb.message) |m| m.deinit();
        }
        callbacks.deinit();
    }

    loop(&gpas, window, &callbacks, &connection, &data, args);

    log.info("Window Closed", .{});
}

fn loop(gpas: *DebugAllocators, window: *glfw.Window, callbacks: *session.Callbacks, connection: *Connection, data: *SessionData, args: Args) void {
    gpas.timer.reset();

    while (!window.shouldClose()) {
        while (true) {
            const ok = connection.queue_messages(1) catch |err| switch (err) {
                error.EndOfStream => blk: { // assume adapter died
                    connection.adapter_died();
                    break :blk false;
                },
                else => blk: {
                    log.err("queue_messages: {}", .{err});
                    break :blk false;
                },
            };

            if (!ok) break;
        }

        session.send_queued_requests(connection, data);
        const handled_message = session.handle_queued_messages(callbacks, data, connection);
        session.handle_callbacks(callbacks, data, connection);

        if (handled_message) {
            ui.continue_rendering();
        }
        ui.ui_tick(gpas, window, callbacks, connection, data, args);
    }
}

pub const Args = struct {
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
        if (std.mem.eql(u8, arg, "--cwd")) {
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

test "imports" {
    _ = @import("ini.zig");
}
