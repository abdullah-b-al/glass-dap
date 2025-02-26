const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const fmt = std.fmt;
const ascii = std.ascii;
const testing = std.testing;

pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayListUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) Diagnostic {
        return .{ .allocator = allocator, .messages = .empty };
    }

    pub fn add_message(diag: *Diagnostic, comptime format: []const u8, args: anytype) void {
        diag.messages.ensureUnusedCapacity(diag.allocator, 1) catch return;
        const message = fmt.allocPrint(diag.allocator, format, args) catch "OOM";
        diag.messages.appendAssumeCapacity(message);
    }

    pub fn deinit(diag: *Diagnostic) void {
        for (diag.messages.items) |message| {
            diag.allocator.free(message);
        }
        diag.messages.deinit(diag.allocator);
    }
};

pub const Type = union(enum) {
    string: []const u8,
    string_array: []const []const u8,
    integer: i64,
    float: f64,
    bool: bool,
};

pub const Section = struct {
    const Entry = std.StringArrayHashMap(EntryValue).Entry;

    name: []const u8,
    entries: std.StringArrayHashMap(EntryValue),
    /// one based
    line: usize,

    pub fn deinit(self: *Section) void {
        self.entries.deinit();
    }
};
pub const EntryValue = struct {
    value: Type,
    /// one based
    line: usize,
};

fn set_or_return_error(maybe_diag: ?*Diagnostic, err: anyerror, comptime format: []const u8, args: anytype) !void {
    if (maybe_diag) |diag| {
        diag.add_message(format, args);
    } else {
        return err;
    }
}

pub fn parse_from_slice_leaky(arena: std.mem.Allocator, slice: []const u8, diag: ?*Diagnostic) ![]Section {
    var sections = std.ArrayList(Section).init(arena);

    var iter_section = SectionIterator.init(slice);
    next_section: while (try iter_section.next()) |section| {
        const current_index = if (iter_section.i < slice.len) iter_section.i else slice.len;
        var line_number: usize = mem.count(u8, slice[0..current_index], "\n");

        var entries = std.StringArrayHashMap(EntryValue).init(arena);

        var iter_line = mem.splitScalar(u8, section, '\n');
        const header = try arena.dupe(u8, mem.trim(u8, iter_line.next().?, " \t[]"));
        const header_line = line_number;

        while (iter_line.next()) |line| {
            line_number += 1;

            if (mem.indexOfNone(u8, line, &ascii.whitespace) == null) {
                // empty line
                continue;
            }

            if (mem.indexOfScalar(u8, line, '=') == null) {
                try set_or_return_error(diag, error.InvalidEntry, "At line {} entry without an assignment\n", .{line_number});
                continue :next_section;
            }

            var split_assign = mem.splitScalar(u8, line, '=');
            const lhs = mem.trim(u8, split_assign.next().?, &ascii.whitespace);
            const rhs = mem.trim(u8, split_assign.next().?, &ascii.whitespace);

            if (lhs.len == 0) {
                try set_or_return_error(diag, error.InvalidEntry, "At line {} entry without a key\n", .{line_number});
                continue :next_section;
            }

            if (entries.contains(lhs)) {
                try set_or_return_error(diag, error.DuplicateEntry, "At line {} duplicate entry {s}\n", .{ line_number, lhs });
                continue :next_section;
            }
            try entries.ensureUnusedCapacity(1);
            const value = try parse_value(arena, rhs);
            const cloned_lhs = try arena.dupe(u8, lhs);
            entries.putAssumeCapacity(cloned_lhs, .{ .value = value, .line = line_number });
        } // fill entries

        try sections.append(.{
            .name = header,
            .entries = try entries.clone(),
            .line = header_line,
        });
    }

    return try sections.toOwnedSlice();
}

/// Always allocates strings
pub fn parse_value(arena: std.mem.Allocator, value: []const u8) !Type {
    if (value.len == 0) {
        return .{ .string = "" };
    }
    if (value.len >= 2 and (value[0] == '[' and value[value.len - 1] == ']')) {
        var list = std.ArrayList([]const u8).init(arena);
        var lexer = StringArrayParser.init(value);
        while (try lexer.next(arena)) |item| {
            try list.append(item);
        }

        return .{ .string_array = list.items };
    } else if (value.len >= 2 and (value[0] == '[' and value[value.len - 1] != ']')) {
        return error.InvalidStringArray;
    }

    if (mem.eql(u8, value, "true")) {
        return .{ .bool = true };
    } else if (mem.eql(u8, value, "false")) {
        return .{ .bool = false };
    }

    if (fmt.parseInt(i64, value, 10)) |int| {
        return .{ .integer = int };
    } else |_| {}

    if (fmt.parseFloat(f64, value)) |float| {
        return .{ .float = float };
    } else |_| {}

    // assume string
    var result =
        if (value[0] == '"')
        try parse_string_until(arena, value[1..], '"') orelse return error.InvalidString
    else
        (try parse_string_until(arena, value, null)).?;

    result = try escape_characters(result);
    return .{ .string = result };
}

/// Parses a string until the un-escaped `delimiter` or if `delimiter` is null end of string
/// Returns null if the `delimiter` isn't found
fn parse_string_until(arena: std.mem.Allocator, value: []const u8, delimiter: ?u8) !?[]u8 {
    var i: usize = 0;
    var found_delimiter = false;
    while (i < value.len) : (i += 1) {
        const c = value[i];

        if (c == '\\') {
            if (i + 1 < value.len) {
                const next_c = value[i + 1];
                if (next_c == '\\' or next_c == delimiter) {
                    i += 1;
                    continue;
                }
            } else {
                return error.InvalidEscape;
            }
        }

        if (c == delimiter) {
            found_delimiter = true;
            break;
        }
    }

    if (delimiter != null and !found_delimiter) {
        return null;
    }

    return try arena.dupe(u8, value[0..i]);
}

fn find_escaped_charcter(string: []const u8, escaped: u8) !?usize {
    const i = mem.indexOfScalar(u8, string, '\\') orelse return null;
    if (i + 1 < string.len and string[i + 1] == escaped) {
        return i + 1;
    }

    if (i + 1 >= string.len) {
        return error.InvalidEscape;
    }

    return null;
}

fn escaped_character_count(buf: []const u8, escaped: u8) !usize {
    var count: usize = 0;

    var string = buf;
    while (try find_escaped_charcter(string, escaped)) |i| {
        count += 1;
        string = string[i..];
    }

    return count;
}

/// Safe to free if using an arena
fn escape_characters(buf: []u8) ![]u8 {
    const map = std.StaticStringMap(u8).initComptime(.{
        .{ "\"", '"' },
        .{ "\\", '\\' },
        .{ "t", '\t' },
        .{ "n", '\n' },
    });

    var len = buf.len;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i + 1 < len) {
            const next_c = buf[i + 1];
            if (buf[i] == '\\' and map.has(&.{next_c})) {
                buf[i + 1] = map.get(&.{next_c}).?;
                mem.copyForwards(u8, buf[i..], buf[i + 1 ..]);
                len -= 1;
            }
        } else {
            if (buf[i] == '\\') {
                return error.InvalidEscape;
            }
        }
    }

    return buf[0..len];
}

/// Parses an array of strings escaping double quotes and duplicating all values
pub const StringArrayParser = struct {
    rest: []const u8,

    fn init(slice: []const u8) StringArrayParser {
        std.debug.assert(slice[0] == '[' and slice[slice.len - 1] == ']');
        return .{ .rest = slice };
    }

    pub fn next(self: *StringArrayParser, arena: std.mem.Allocator) !?[]const u8 {
        while (self.rest.len > 0) {
            self.rest = mem.trimLeft(u8, self.rest, &ascii.whitespace);
            if (self.rest.len == 0) return null;

            switch (self.rest[0]) {
                '"' => {
                    const result = try parse_string_until(arena, self.rest[1..], '"') orelse return error.InvalidString;
                    self.rest = self.rest[result.len + 2 ..]; // +2 for two double quotes

                    if (self.rest.len > 0 and (self.rest[0] == ']' or self.rest[0] == ',')) {
                        return result;
                    } else {
                        return error.InvalidStringElement;
                    }
                },

                ',', '[', ']' => {
                    self.rest = self.rest[1..];
                },

                else => {
                    var result = try parse_string_until(arena, self.rest, ',') orelse
                        try parse_string_until(arena, self.rest, ']') orelse
                        return error.InvalidStringElement;

                    const escaped_double_qoute_count = try escaped_character_count(result, '"');

                    const double_qoute_count = mem.count(u8, result, "\"");

                    if (escaped_double_qoute_count != double_qoute_count) {
                        return error.InvalidString;
                    }

                    self.rest = self.rest[result.len..];

                    result = try escape_characters(result);
                    return result;
                },
            }
        }

        return null;
    }
};

pub const SectionIterator = struct {
    slice: []const u8,
    i: usize,

    fn init(slice: []const u8) SectionIterator {
        return .{ .slice = slice, .i = 0 };
    }

    pub fn next(section: *SectionIterator) !?[]const u8 {
        if (section.i >= section.slice.len) return null;

        const start = section.next_header_index() orelse return null;
        if (start.err) |err| return err;

        var copy = section.*;
        const end = copy.next_header_index() orelse IndexResult{ .err = null, .index = section.slice.len };
        if (end.err) |err| switch (err) {
            error.InvalidHeader => {}, // handle next call
        };

        return section.slice[start.index..end.index];
    }

    const IndexResult = struct {
        err: ?error{InvalidHeader},
        index: usize,
    };

    fn next_header_index(section: *SectionIterator) ?IndexResult {
        if (section.i >= section.slice.len) return null;

        var iter = mem.splitScalar(u8, section.slice[section.i..], '\n');
        while (iter.next()) |line| {
            const i = section.i;
            section.i += line.len + 1;

            const trimmed = mem.trim(u8, line, " \t");
            if (trimmed.len < 2) {
                continue;
            } else if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                return .{
                    .index = i,
                    .err = if (mem.count(u8, line, "[") != 1 or mem.count(u8, line, "]") != 1)
                        error.InvalidHeader
                    else
                        null,
                };
            }
        }

        return null;
    }
};

test "section iterator" {
    const sections = [_][]const u8{
        \\[adapters.foo]
        \\    id = foo
        \\    type = bar
        \\    command = baz
        \\
        ,
        \\          [adapters.foo]   
        \\    id = foo
        \\    type = bar
        \\
        ,
        \\      [adapters.bar][]
        \\    id = bar
        \\    type = foo
        \\
    };
    const content = comptime blk: {
        var content: []const u8 = "";
        for (sections) |section| {
            content = content ++ section;
        }
        break :blk content;
    };

    var iter_section = SectionIterator.init(content);
    try testing.expectEqualStrings((try iter_section.next()).?, sections[0]);
    try testing.expectEqualStrings((try iter_section.next()).?, sections[1]);
    try testing.expectError(error.InvalidHeader, iter_section.next());
}

test "parse_from_slice_leaky: invalid entries" {
    const sections = [_][]const u8{
        \\      [adapters.bar]
        \\    id =
        \\    type = foo
        \\
        ,
        \\      [adapters.bar]
        \\    =
        \\    type = foo
        \\
        ,
        \\      [adapters.bar]
        \\    type = foo
        \\    = value
        \\
        ,
        \\      [adapters.bar]
        \\    id
        \\    type = foo
        \\
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try parse_from_slice_leaky(arena.allocator(), sections[0], null);
    const section_1 = parse_from_slice_leaky(arena.allocator(), sections[1], null);
    const section_2 = parse_from_slice_leaky(arena.allocator(), sections[2], null);
    const section_3 = parse_from_slice_leaky(arena.allocator(), sections[3], null);

    try testing.expectError(error.InvalidEntry, section_1);
    try testing.expectError(error.InvalidEntry, section_2);
    try testing.expectError(error.InvalidEntry, section_3);
}

test "parse_value: simple values" {
    const sections = [_][]const u8{
        \\    [Test]
        \\    one = this is one
        \\    two = "this is two"
        \\    bool = true
        ,
        \\    [Test]
        \\    two = two alone
        \\    bool = true
        ,
        \\    [Test]
        ,
        \\    [Test]
        \\    two = two with three
        \\    three = 3
        \\    bool = false
        ,
        \\    [Test]
        \\    two = "two with \n newline"
        ,
        \\    [Test]
        \\    two = two without \\n newline
        ,
        \\    [Test]
        \\    two = many escapes \"\\\t\n\\\"\\\"
        ,
        \\    [Test]
        \\    two = Invalid \
    };

    const expected_results = .{
        .{ .one = Type{ .string = "this is one" }, .two = Type{ .string = "this is two" }, .bool = Type{ .bool = true } },
        .{ .two = Type{ .string = "two alone" }, .bool = Type{ .bool = true } },
        .{},
        .{ .two = Type{ .string = "two with three" }, .three = Type{ .integer = 3 }, .bool = Type{ .bool = false } },
        .{ .two = Type{ .string = "two with \n newline" } },
        .{ .two = Type{ .string = "two without \\n newline" } },
        .{ .two = Type{ .string = "many escapes \"\\\t\n\\\"\\\"" } },
        error.InvalidEscape,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    inline for (sections, expected_results, 0..) |section, expected, i| {
        errdefer std.debug.print("Failed {}\n", .{i});

        switch (@typeInfo(@TypeOf(expected))) {
            .@"struct" => {
                const parsed = try parse_from_slice_leaky(arena.allocator(), section, null);
                inline for (meta.fields(@TypeOf(expected)), parsed[0].entries.keys(), parsed[0].entries.values()) |field, key, entry| {
                    try testing.expectEqualStrings(field.name, key);
                    const field_value = @field(expected, field.name);
                    try testing.expectEqualDeep(field_value, entry.value);
                }
            },
            else => {
                const parsed = parse_from_slice_leaky(arena.allocator(), section, null);
                try testing.expectError(expected, parsed);
            },
        }
    }
}

test "parse_entries: string arrays" {
    const sections = [_][]const u8{
        \\    [Test]
        \\    args = [Hello, there, !]
        ,
        \\    [Test]
        \\    args = ["Hello", there, "!"]
        ,
        \\    [Test]
        \\    args = [Hello, "there, !]
        ,
        \\    [Test]
        \\    args = [Hello", there, !]
        ,
        \\    [Test]
        \\    args = [Hello\", there, !]
        ,
        \\    [Test]
        \\    args = [Hello\"", there, !]
        ,
        \\    [Test]
        \\    args = [Hello, "there" invalid string, !]
        ,
        \\    [Test]
        \\    args = [Hello, there, !
        ,
    };

    const expected_results = .{
        .{ .args = Type{ .string_array = &.{ "Hello", "there", "!" } } },
        .{ .args = Type{ .string_array = &.{ "Hello", "there", "!" } } },
        error.InvalidString,
        error.InvalidString,
        .{ .args = Type{ .string_array = &.{ "Hello\"", "there", "!" } } },
        error.InvalidString,
        error.InvalidStringElement,
        error.InvalidStringArray,
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    inline for (sections, expected_results, 0..) |section, expected, i| {
        errdefer std.debug.print("Failed {}\n", .{i});
        switch (@typeInfo(@TypeOf(expected))) {
            .@"struct" => {
                const parsed = try parse_from_slice_leaky(arena.allocator(), section, null);
                inline for (meta.fields(@TypeOf(expected)), parsed[0].entries.keys(), parsed[0].entries.values()) |field, key, entry| {
                    try testing.expectEqualStrings(field.name, key);
                    const field_value = @field(expected, field.name);
                    try testing.expectEqualDeep(field_value, entry.value);
                }
            },
            else => {
                const parsed = parse_from_slice_leaky(arena.allocator(), section, null);
                try testing.expectError(expected, parsed);
            },
        }
    }
}
