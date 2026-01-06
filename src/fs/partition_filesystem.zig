const std = @import("std");
const crypto = @import("../crypto/mod.zig");
pub const FileReader = @import("file_reader.zig").FileReader;
pub const File = @import("file.zig").File;
const Directory = @import("directory.zig").Directory;

const Header = extern struct {
    magic: [4]u8 align(1),
    entry_count: u32,
    string_table_size: u32,
    _reserved_xc: u32,
};

const PfsEntry = extern struct {
    offset: u64,
    size: u64,
    string_offset: u32,
    _reserved_xc: u32,
};

const HfsEntry = extern struct {
    offset: u64,
    size: u64,
    string_offset: u32,
    hashed_region_size: u32,
    _reserved_x18: u64,
    hash: [0x20]u8 align(1),
};

pub const PartitionFilesystem = struct {
    root_dir: Directory,

    fn init(allocator: std.mem.Allocator, magic: [4]u8, Entry: type, file: *const File) !PartitionFilesystem {
        var self: PartitionFilesystem = undefined;
        self.root_dir = try Directory.init(allocator);

        var buffer: [0x800]u8 = undefined;
        var reader: FileReader = undefined;
        try file.createReader(&reader, &buffer, 0);

        // Header
        const header = try reader.interface.takeStruct(Header, .little);
        if (!std.mem.eql(u8, &header.magic, &magic)) {
            return error.InvalidPfsMagic;
        }

        // Offsets
        const entries_offset = reader.interface.seek;
        const string_table_offset = entries_offset + header.entry_count * @sizeOf(Entry);
        const data_offset = string_table_offset + header.string_table_size;

        // String table
        _ = try reader.interface.discard(.limited(string_table_offset - @sizeOf(Header)));
        var string_table = try allocator.alloc(u8, header.string_table_size);
        defer allocator.free(string_table);

        try reader.interface.readSliceAll(string_table);

        // Entries
        try file.createReader(&reader, &buffer, entries_offset);
        for (0..header.entry_count) |_| {
            const entry = try reader.interface.takeStruct(Entry, .little);
            const entry_name = std.mem.sliceTo(string_table[entry.string_offset..], 0);
            const entry_data_offset = data_offset + entry.offset;

            const file_entry = File.initViewInheritingCrypto(file, entry_data_offset, entry.size);
            try self.root_dir.addFile(entry_name, file_entry);
        }

        return self;
    }

    pub fn initPfs(allocator: std.mem.Allocator, file: *const File) !PartitionFilesystem {
        return try init(allocator, "PFS0".*, PfsEntry, file);
    }

    pub fn initHfs(allocator: std.mem.Allocator, file: *const File) !PartitionFilesystem {
        return try init(allocator, "HFS0".*, HfsEntry, file);
    }

    pub fn deinit(self: *PartitionFilesystem) void {
        self.root_dir.deinit();
    }
};
