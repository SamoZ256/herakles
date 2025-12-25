const std = @import("std");

pub const DiskStorage = struct {
    handle: *const std.fs.File,

    pub fn init(handle: *const std.fs.File) DiskStorage {
        return .{
            .handle = handle,
        };
    }

    pub fn getSize(self: DiskStorage) !u64 {
        return (try self.handle.stat()).size;
    }

    pub fn createReader(self: DiskStorage, buffer: []u8) !std.fs.File.Reader {
        return self.handle.reader(buffer);
    }
};
