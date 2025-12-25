const std = @import("std");
const crypto = @import("../crypto/mod.zig");
const DiskStorage = @import("disk_storage.zig").DiskStorage;
const MemoryStorage = @import("memory_storage.zig").MemoryStorage;
const FileReader = @import("file_reader.zig").FileReader;

const Storage = union(enum) {
    disk: *const DiskStorage,
    memory: *const MemoryStorage,

    pub fn getSize(self: Storage) !u64 {
        return switch (self) {
            .disk => |disk| try disk.getSize(),
            .memory => |memory| memory.getSize(),
        };
    }

    pub fn createReader(self: Storage, buffer: []u8) !FileReader.Base {
        return switch (self) {
            .disk => |disk| .{ .disk = try disk.createReader(buffer) },
            .memory => |memory| .{ .memory = memory.createReader() },
        };
    }
};

pub const File = struct {
    storage: Storage,
    offset: u64,
    size: u64,
    crypto_ctx: ?crypto.aes.Context = null,
    crypto_offset: u64 = 0,

    fn initBase(storage: Storage) !File {
        return .{
            .storage = storage,
            .offset = 0,
            .size = try storage.getSize(),
        };
    }

    pub fn initWithDiskStorage(storage: *const DiskStorage) !File {
        return initBase(.{ .disk = storage });
    }

    pub fn initWithMemoryStorage(storage: *const MemoryStorage) File {
        return initBase(.{ .memory = storage }) catch unreachable;
    }

    pub fn initView(base: *const File, offset: u64, size: u64) File {
        return .{
            .storage = base.storage,
            .offset = base.offset + offset,
            .size = size,
        };
    }

    pub fn initViewInheritingCrypto(base: *const File, offset: u64, size: u64) File {
        var self = initView(base, offset, size);
        self.setCrypto(base.crypto_ctx, base.crypto_offset + offset);
        return self;
    }

    pub fn setCrypto(self: *File, crypto_ctx: ?crypto.aes.Context, crypto_offset: u64) void {
        self.crypto_ctx = crypto_ctx;
        self.crypto_offset = crypto_offset;
    }

    pub fn createReader(self: *const File, reader: *FileReader, buffer: []u8, offset: u64) !void {
        var base = try self.storage.createReader(buffer);
        try base.seekTo(self.offset + offset);
        reader.base = base;

        // Crypto reader
        const base_interface = reader.base.interface();
        if (self.crypto_ctx) |*crypto_ctx| {
            reader.crypto_reader = crypto.aes.Reader.init(base_interface, crypto_ctx, self.crypto_offset + offset, buffer);
            reader.interface = &(reader.crypto_reader orelse unreachable).interface;
        } else {
            reader.crypto_reader = null;
            reader.interface = base_interface;
        }
    }

    // TODO
    //pub fn createWriter(self: *const File, buffer: []u8) !std.fs.File.Writer {
    //    var writer = self.getHandle().writer(buffer);
    //    try writer.seekTo(self.getOffset());
    //    return writer;
    //}

    pub fn save(self: *const File, path: []const u8) !void {
        std.debug.print("Saving {s}\n", .{path});

        // Reader
        var read_buffer: [4096]u8 = undefined;
        var reader: FileReader = undefined;
        try self.createReader(&reader, &read_buffer, 0);

        // File
        var file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        // Writer
        var write_buffer: [4096]u8 = undefined;
        var writer = file.writer(&write_buffer);

        // Copy data
        var tmp_buff: [4096]u8 = undefined;
        var seek: u64 = 0;
        while (true) {
            const count = @min(self.size - seek, tmp_buff.len);
            if (count == 0) break;

            const buff = tmp_buff[0..count];
            try reader.interface.readSliceAll(buff);
            try writer.interface.writeAll(buff);
            seek += count;
        }

        // Flush
        try writer.interface.flush();
    }

    pub fn format(self: *const File, writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.print("(size: {x})", .{self.size});
    }
};
