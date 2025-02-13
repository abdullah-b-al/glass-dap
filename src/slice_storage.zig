const std = @import("std");

const StringHashContext = struct {
    const String = []const u8;

    pub fn hash(self: @This(), s: String) u64 {
        _ = self;
        return std.hash_map.hashString(s);
    }
    pub fn eql(self: @This(), a: String, b: String) bool {
        _ = self;
        return std.hash_map.eqlString(a, b);
    }
};

pub const StringStorage = SliceStorage(u8, StringHashContext);

pub const StringStorageUnmanaged = SliceStorageUnmanaged(u8, StringHashContext);

pub fn SliceStorage(comptime T: type, comptime HashContext: type) type {
    return struct {
        const Self = @This();

        const Unmanaged = SliceStorageUnmanaged(T, HashContext);
        const Slice = Unmanaged.Slice;

        unmanaged: Unmanaged = .{},
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.unmanaged.deinit(self.allocator);
        }

        pub fn get_and_put(self: *Self, slice: Slice) !Slice {
            return self.unmanaged.get_and_put(self.allocator, slice);
        }

        pub fn put(self: *Self, arg_slice: Slice) !void {
            try self.unmanaged.put(self.allocator, arg_slice);
        }

        pub fn get(self: *Self, slice: Slice) ?Slice {
            return self.unmanaged.get(slice);
        }

        pub fn remove(self: *Self, arg_slice: Slice) void {
            self.unmanaged.remove(self.allocator, arg_slice);
        }

        pub fn ensure_unused_capacity(self: *Self, additional_size: Unmanaged.HashMapUnmanaged.Size) !void {
            try self.unmanaged.ensure_unused_capacity(self.allocator, additional_size);
        }
    };
}

pub fn SliceStorageUnmanaged(comptime T: type, comptime HashContext: type) type {
    return struct {
        const Self = @This();
        pub const Slice = []const T;

        pub const empty = Self{ .set = .empty };
        pub const HashMapUnmanaged = std.HashMapUnmanaged(Slice, void, HashContext, std.hash_map.default_max_load_percentage);
        set: HashMapUnmanaged,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var iter = self.set.keyIterator();
            while (iter.next()) |slice|
                allocator.free(slice.*);

            self.set.deinit(allocator);
        }

        pub fn get_and_put(self: *Self, allocator: std.mem.Allocator, slice: Slice) !Slice {
            try self.put(allocator, slice);
            return self.get(slice).?;
        }

        pub fn put(self: *Self, allocator: std.mem.Allocator, arg_slice: Slice) !void {
            const stored_slice: ?Slice = self.set.getKey(arg_slice);

            if (stored_slice == null) {
                try self.set.ensureUnusedCapacity(allocator, 1);
                const slice = try allocator.dupe(T, arg_slice);
                self.set.putAssumeCapacity(slice, {});
            }
        }

        pub fn get(self: *Self, slice: Slice) ?Slice {
            const stored_string = self.set.getKey(slice) orelse return null;
            return stored_string;
        }

        pub fn remove(self: *Self, allocator: std.mem.Allocator, slice: Slice) void {
            const stored_slice = self.set.getKey(slice) orelse return;
            _ = self.set.remove(stored_slice);
            allocator.free(stored_slice);
        }

        pub fn ensure_unused_capacity(self: *Self, allocator: std.mem.Allocator, additional_size: HashMapUnmanaged.Size) !void {
            try self.set.ensureUnusedCapacity(allocator, additional_size);
        }
    };
}
