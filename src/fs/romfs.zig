const std = @import("std");
pub const FileReader = @import("file_reader.zig").FileReader;
pub const File = @import("file.zig").File;
const Directory = @import("directory.zig").Directory;

const TableLocation = extern struct {
    offset: u64,
    size: u64,
};

const Header = extern struct {
    header_size: u64,
    directory_hash: TableLocation,
    directory_meta: TableLocation,
    file_hash: TableLocation,
    file_meta: TableLocation,
    data_offset: u64,
};

const FileEntry = extern struct {
    parent: u32,
    sibling: u32,
    offset: u64,
    size: u64,
    hash: u32,
    name_length: u32,
};

const DirectoryEntry = extern struct {
    parent: u32,
    sibling: u32,
    child_dir: u32,
    child_file: u32,
    hash: u32,
    name_length: u32,
};

const entry_empty = 0xffffffff;
const empty_name_placeholder = "__EMPTY__";

const RomFSParser = struct {
    allocator: std.heap.ArenaAllocator,
    data_file: *const File,
    file_meta: []u8,
    directory_meta: []u8,

    pub fn init(file: *const File, data_file: *const File, file_meta_loc: TableLocation, directory_meta_loc: TableLocation) !RomFSParser {
        var self: RomFSParser = undefined;
        self.allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        self.data_file = data_file;

        // File meta
        var buffer: [0x800]u8 = undefined;
        var reader: FileReader = undefined;
        try file.createReader(&reader, &buffer, file_meta_loc.offset);
        self.file_meta = try reader.interface.readAlloc(self.allocator.allocator(), file_meta_loc.size);

        // Directory meta
        try file.createReader(&reader, &buffer, directory_meta_loc.offset);
        self.directory_meta = try reader.interface.readAlloc(self.allocator.allocator(), directory_meta_loc.size);

        return self;
    }

    pub fn deinit(self: *RomFSParser) void {
        self.allocator.deinit();
    }

    fn Entry(T: type) type {
        return struct {
            data: T,
            name: []const u8,
        };
    }

    fn readEntry(self: *const RomFSParser, T: type, comptime meta_member: []const u8, offset: u32) Entry(T) {
        const meta = @field(self, meta_member);

        var entry: Entry(T) = undefined;
        entry.data = @as(*align(1) T, @ptrCast(meta[offset..][0..@sizeOf(T)])).*;
        entry.name = meta[offset + @sizeOf(T) ..][0..entry.data.name_length];
        if (entry.name.len == 0) {
            entry.name = empty_name_placeholder;
        }

        return entry;
    }

    pub fn readFile(self: *const RomFSParser, parent: *Directory, offset: u32) !void {
        var off = offset;
        while (off != entry_empty) {
            const entry = self.readEntry(FileEntry, "file_meta", off);

            const file = File.initViewInheritingCrypto(self.data_file, entry.data.offset, entry.data.size);
            try parent.addFile(entry.name, file);
            off = entry.data.sibling;
        }
    }

    pub fn readDirectory(self: *const RomFSParser, allocator: std.mem.Allocator, parent: *Directory, offset: u32) !void {
        var off = offset;
        while (off != entry_empty) {
            const entry = self.readEntry(DirectoryEntry, "directory_meta", off);

            var dir = try Directory.init(allocator);
            try self.readFile(&dir, entry.data.child_file);
            try self.readDirectory(allocator, &dir, entry.data.child_dir);

            try parent.addDirectory(entry.name, dir);
            off = entry.data.sibling;
        }
    }
};

pub const RomFS = struct {
    root_dir: Directory,

    pub fn init(allocator: std.mem.Allocator, file: *const File) !RomFS {
        var self: RomFS = undefined;
        self.root_dir = try Directory.init(allocator);

        var buffer: [256]u8 = undefined;
        var reader: FileReader = undefined;
        try file.createReader(&reader, &buffer, 0);

        // Header
        const header = try reader.interface.takeStruct(Header, .little);
        if (header.header_size != @sizeOf(Header)) {
            return error.InvalidRomFSHeaderSize;
        }

        // Content
        const data_file = File.initViewInheritingCrypto(file, header.data_offset, file.size - header.data_offset);
        const parser = try RomFSParser.init(file, &data_file, header.file_meta, header.directory_meta);
        var root_container = try Directory.init(allocator);
        defer root_container.deinit();
        try parser.readDirectory(allocator, &root_container, 0);

        // Root
        self.root_dir = (try root_container.getDirectory(empty_name_placeholder)).*;

        return self;
    }

    pub fn deinit(self: *RomFS) void {
        self.root_dir.deinit();
    }
};
