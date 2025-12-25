const std = @import("std");

pub const MemoryStorage = struct {
    buffer: []u8,

    pub fn init(buffer: []u8) MemoryStorage {
        return .{
            .buffer = buffer,
        };
    }

    pub fn getSize(self: MemoryStorage) u64 {
        return @intCast(self.buffer.len);
    }

    pub fn createReader(self: MemoryStorage) std.io.Reader {
        return std.io.Reader.fixed(self.buffer);
    }
};
