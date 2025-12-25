const std = @import("std");

pub fn OwnedStringMap(comptime V: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        map: std.StringHashMap(V),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .map = std.StringHashMap(V).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.map.deinit();
        }

        pub fn put(self: *Self, key: []const u8, value: V) !?V {
            if (self.map.getPtr(key)) |existing_value| {
                const old_value = existing_value.*;
                existing_value.* = value;
                return old_value;
            }

            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);

            try self.map.put(owned_key, value);
            return null;
        }

        pub fn get(self: Self, key: []const u8) ?V {
            return self.map.get(key);
        }

        pub fn getPtr(self: *const Self, key: []const u8) ?*V {
            return self.map.getPtr(key);
        }

        pub fn contains(self: Self, key: []const u8) bool {
            return self.map.contains(key);
        }

        pub fn remove(self: *Self, key: []const u8) ?V {
            if (self.map.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                return kv.value;
            }
            return null;
        }

        pub fn count(self: Self) usize {
            return self.map.count();
        }

        pub fn clearAndFree(self: *Self) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.map.clearAndFree();
        }

        pub fn iterator(self: *const Self) std.StringHashMap(V).Iterator {
            return self.map.iterator();
        }
    };
}
