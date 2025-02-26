const std = @import("std");
const protocol = @import("protocol.zig");
const zgui = @import("zgui");
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;
const folders = @import("known-folders");
const ini = @import("ini.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const json = std.json;

pub const config_dir_name = "glass-dap";
pub const config_file_name = "config.ini";

pub var app = Config.init(std.heap.page_allocator);

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    adapters: Adapters,
    projects: Projects,
    mappings: Mappings,

    diagnostic: ini.Diagnostic,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .adapters = .empty,
            .projects = .empty,
            .mappings = .empty,
            .diagnostic = ini.Diagnostic.init(allocator),
        };
    }

    pub fn deinit(config: *Config) void {
        config.diagnostic.deinit();
        config.arena.deinit();
    }
};

pub const Path = std.BoundedArray(u8, std.fs.max_path_bytes);
pub const Object = std.json.ArrayHashMap(std.json.Value);
pub const Entry = struct { key: []const u8, value: ini.Type };

pub const Mappings = std.AutoArrayHashMapUnmanaged(Key, Action);
pub const Adapters = std.StringArrayHashMapUnmanaged([]const Entry);
/// Each project has a list of configurations where each config is an object,
/// representing a launch or attach request arguments.
pub const Projects = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(Object));

pub const Action = enum {
    continue_threads,
    pause,
    next_line,
    next_statement,
    next_instruction,
    begin_session,
    toggle_debug_ui,
};

pub const Key = struct {
    pub const Mod = enum { alt, control, shift };
    pub const Mods = std.EnumSet(Mod);

    mods: Mods,
    key: zgui.Key,

    pub fn from_string(string: []const u8) ?Key {
        var key = Key{ .mods = Mods.initEmpty(), .key = .none };

        var iter = mem.splitScalar(u8, string, ' ');
        while (iter.next()) |str| {
            if (meta.stringToEnum(Mod, str)) |mod| {
                key.mods.insert(mod);
            } else if (meta.stringToEnum(zgui.Key, str)) |k| {
                key.key = k;
            }
        }

        if (key.key != .none) {
            return key;
        } else {
            return null;
        }
    }
};

pub fn open_config_file(allocator: std.mem.Allocator) !fs.File {
    const parent_path = try folders.getPath(allocator, .local_configuration) orelse return error.ConfigDirectoryDoesNotExist;
    defer allocator.free(parent_path);
    const path = try fs.path.join(allocator, &.{ parent_path, config_dir_name });
    defer allocator.free(path);

    var dir = try fs.openDirAbsolute(path, .{});
    defer dir.close();

    return try dir.openFile(config_file_name, .{ .mode = .read_only });
}

pub fn parse_config(gpa: std.mem.Allocator, content: []const u8) !Config {
    const Section = enum {
        adapters,
        configurations,
        @"key mappings",
        unknown,
    };

    var config = Config{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .adapters = .empty,
        .projects = .empty,
        .mappings = .empty,
        .diagnostic = ini.Diagnostic.init(gpa),
    };
    const arena = config.arena.allocator();

    const sections = try ini.parse_from_slice_leaky(arena, content, &config.diagnostic);

    next_section: for (sections) |section| {
        const section_name, const subsection = blk: {
            const i = mem.indexOfScalar(u8, section.name, '.') orelse section.name.len;
            const j = if (i == section.name.len) i else i + 1;
            break :blk .{ section.name[0..i], section.name[j..] };
        };

        switch (meta.stringToEnum(Section, section_name) orelse .unknown) {
            .adapters => {
                if (subsection.len == 0) {
                    config.diagnostic.add_message(
                        "Section [{s}] Line {}: Invalid Subsection '{s}'\n",
                        .{ section.name, section.line, subsection },
                    );
                    continue :next_section;
                }

                const adapter_name = subsection;

                if (config.adapters.contains(adapter_name)) {
                    config.diagnostic.add_message(
                        "Section [{s}] Line {}: Duplicate Adapters sections are not allowed\n",
                        .{ section.name, section.line },
                    );
                    continue :next_section;
                }

                try config.adapters.ensureUnusedCapacity(arena, 1);
                const list = try section_to_entries(arena, section);
                config.adapters.putAssumeCapacity(adapter_name, list);
            },
            .configurations => {
                if (subsection.len == 0) {
                    config.diagnostic.add_message(
                        "Section [{s}] Line {}: Invalid Subsection '{s}'\n",
                        .{ section.name, section.line, subsection },
                    );
                    continue :next_section;
                }
                const language_name = subsection;

                try config.projects.ensureUnusedCapacity(arena, 1);
                const list_gop = try config.projects.getOrPut(arena, language_name);
                if (!list_gop.found_existing) list_gop.value_ptr.* = .empty;
                try list_gop.value_ptr.ensureUnusedCapacity(arena, 1);

                const object = try section_to_object(arena, section);
                list_gop.value_ptr.appendAssumeCapacity(object);
            },
            .@"key mappings" => {
                try config.mappings.ensureTotalCapacity(arena, section.entries.count());
                next_mapping: for (section.entries.keys(), section.entries.values()) |string_key, ini_value| {
                    const string_value = switch (ini_value.value) {
                        .string => |string| string,
                        else => {
                            config.diagnostic.add_message(
                                "Section [{s}] Line {}: Invalid mapping type expected a string\n",
                                .{ section.name, ini_value.line },
                            );
                            continue :next_mapping;
                        },
                    };

                    const action = meta.stringToEnum(Action, string_value) orelse {
                        config.diagnostic.add_message(
                            "Section [{s}] Line {}: Action '{s}' doesn't exist\n",
                            .{ section.name, ini_value.line, string_value },
                        );
                        continue :next_mapping;
                    };

                    const key = Key.from_string(string_key) orelse {
                        config.diagnostic.add_message(
                            "Section [{s}] Line {}: Unknown key '{s}'\n",
                            .{ section.name, ini_value.line, string_key },
                        );
                        continue :next_mapping;
                    };

                    try config.mappings.put(arena, key, action);
                }
            },
            .unknown => {
                config.diagnostic.add_message(
                    "Unknown Section [{s}] Line {}\n",
                    .{ section.name, section.line },
                );
                continue :next_section;
            },
        }
    }

    return config;
}

fn section_to_entries(arena: std.mem.Allocator, section: ini.Section) ![]Entry {
    const list = try arena.alloc(Entry, section.entries.count());
    for (section.entries.keys(), section.entries.values(), list) |key, entry, *target| {
        target.* = .{ .key = key, .value = entry.value };
    }

    return list;
}

fn section_to_object(arena: std.mem.Allocator, section: ini.Section) !Object {
    var object: Object = .{};
    try object.map.ensureTotalCapacity(arena, section.entries.count());

    for (section.entries.keys(), section.entries.values()) |key, entry| {
        const json_value: std.json.Value = switch (entry.value) {
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| .{ .string = s },
            .string_array => |ini_array| blk: {
                var json_array = try json.Array.initCapacity(arena, ini_array.len);
                for (ini_array) |string| {
                    json_array.appendAssumeCapacity(.{ .string = string });
                }

                break :blk .{ .array = json_array };
            },
        };
        object.map.putAssumeCapacity(key, json_value);
    }

    return object;
}

pub fn find_launch_json() !?Path {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&buf);

    var opened = try std.fs.openDirAbsolute(cwd, .{ .iterate = true });
    var iter = opened.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;

        if (std.mem.eql(u8, entry.name, "launch.json")) {
            var fixed_buf: [std.fs.max_path_bytes]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&fixed_buf);

            const dir = try std.process.getCwd(&buf);
            const path = try std.fs.path.join(fixed.allocator(), &.{ dir, "launch.json" });
            return try Path.fromSlice(path);
        }
    }

    return null;
}

// TODO: Use this again
pub fn open_and_parse_launch_json(allocator: std.mem.Allocator, path: Path) !std.json.Parsed(Object) {
    const file = try std.fs.openFileAbsolute(path.slice(), .{ .mode = .read_only });
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(content);
    return std.json.parseFromSlice(Object, allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}
