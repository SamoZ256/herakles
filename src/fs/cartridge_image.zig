const std = @import("std");
const crypto = @import("../crypto/mod.zig");
pub const FileReader = @import("file_reader.zig").FileReader;
pub const File = @import("file.zig").File;
const Directory = @import("directory.zig").Directory;
const PartitionFilesystem = @import("partition_filesystem.zig").PartitionFilesystem;

const page_size = 0x200;
const game_card_start_offset = 0x1000;
const normal_area_offset = 0x10000 - game_card_start_offset;

const RomSize = enum(u8) {
    _1gb = 0xfa,
    _2gb = 0xf8,
    _4gb = 0xf0,
    _8gb = 0xe0,
    _16gb = 0xe1,
    _32gb = 0xe2,
};

const Version = enum(u8) {
    default = 0,
    unknown1 = 1,
    unknown2 = 2,
    t2_supported = 3, // 20.0.0+
};

const Flags = packed struct {
    auto_boot: bool,
    history_erase: bool,
    repair_tool: bool, // 4.0.0+
    different_region_cup_to_terra_device: bool, // 9.0.0+
    different_region_cup_to_global_device: bool, // 9.0.0+
    _padding5: bool,
    _padding6: bool,
    card_header_sign_key: bool, // 11.0.0+
};

const SelSec = enum(u32) {
    t1 = 1,
    t2 = 2,
};

const Header = extern struct {
    signature: [0x100]u8,
    magic: [4]u8,
    rom_area_start_page_address: u32, // in pages
    backup_area_start_page_address: u32,
    // TODO: correct?
    kek_index_and_title_key_dec_index: u8,
    //kek_index: u4,
    //title_key_dec_index: u4,
    rom_size: RomSize,
    version: Version,
    flags: Flags,
    package_id: u64,
    valid_data_end_address: u32, // in pages
    _reserved_x11c: u32,
    _reserved_x120: [0x10]u8, // TODO: IV?
    partition_fs_header_address: u64,
    partition_fs_header_size: u64,
    partition_fs_header_hash: [0x20]u8,
    initial_data_hash: [0x20]u8,
    sel_sec: SelSec,
    sel_t1_key: u32, // always 2
    sel_key: u32, // always 0
    lim_area: u32, // in pages
};

pub const CartridgeImage = struct {
    root_dir: Directory,

    pub fn init(allocator: std.mem.Allocator, file: *const File) !CartridgeImage {
        var self: CartridgeImage = undefined;
        self.root_dir = try Directory.init(allocator);

        var buffer: [0x800]u8 = undefined;
        var reader: FileReader = undefined;
        try file.createReader(&reader, &buffer, 0);

        // Header
        const header = try reader.interface.takeStruct(Header, .little);
        if (!std.mem.eql(u8, &header.magic, "HEAD")) {
            return error.InvalidXciMagic;
        }

        const pfs_file = File.initView(file, normal_area_offset, file.size - normal_area_offset);
        var pfs = try PartitionFilesystem.initHfs(allocator, &pfs_file);
        defer pfs.deinit();

        // Partitions
        try self.processPartition(allocator, &pfs.root_dir, "normal");
        try self.processPartition(allocator, &pfs.root_dir, "secure");
        try self.processPartition(allocator, &pfs.root_dir, "update");

        return self;
    }

    pub fn deinit(self: *CartridgeImage) void {
        self.root_dir.deinit();
    }

    fn processPartition(self: *CartridgeImage, allocator: std.mem.Allocator, dir: *const Directory, name: []const u8) !void {
        const file = try dir.getFile(name);

        var pfs = try PartitionFilesystem.initHfs(allocator, file);
        defer pfs.deinit();

        var dst_dir = try Directory.init(allocator);

        // Entries
        var iter = pfs.root_dir.iterator();
        while (iter.next()) |entry| {
            try dst_dir.addEntry(entry.key_ptr.*, entry.value_ptr.*);

            // TEST
            std.debug.print("ENTRY: {s}\n", .{entry.key_ptr.*});
        }

        try self.root_dir.addDirectory(name, dst_dir);
    }
};
