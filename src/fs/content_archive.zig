const std = @import("std");
const crypto = @import("../crypto/mod.zig");
pub const FileReader = @import("file_reader.zig").FileReader;
pub const File = @import("file.zig").File;
const Directory = @import("directory.zig").Directory;
const PartitionFilesystem = @import("partition_filesystem.zig").PartitionFilesystem;

const ContentArchiveContentType = enum(u8) {
    program = 0,
    meta = 1,
    control = 2,
    manual = 3,
    data = 4,
    public_data = 5,
};

const FsEntry = extern struct {
    start_offset: u32,
    end_offset: u32,
    reserved: u64,
};

const FsType = enum(u8) {
    rom_fs = 0,
    partition_fs = 1,
};

const HashType = enum(u8) {
    auto = 0,
    none = 1,
    hierarchical_sha256_hash = 2,
    hierarchical_integrity_hash = 3,
    auto_sha3 = 4,
    hierarchical_sha3256_hash = 5,
    hierarchical_integrity_sha3_hash = 6,
};

const EncryptionType = enum(u8) {
    auto = 0,
    none = 1,
    aes_xts = 2,
    aes_ctr = 3,
    aes_ctr_ex = 4,
    aes_ctr_skip_layer_hash = 5,
    aes_ctr_ex_skip_layer_hash = 6,
};

const MetaDataHashType = enum(u8) {
    none = 0,
    hierarchical_integrity = 1,
};

const FsHeader = extern struct {
    version: u16,
    type: FsType,
    hash_type: HashType,
    encryption_type: EncryptionType,
    meta_data_hash_type: MetaDataHashType,
    reserved1: [2]u8 align(1),
    data: extern union {
        hierarchical_sha256_data: extern struct {
            master_hash: [0x20]u8 align(1),
            block_size: u32,
            layer_count: u32, // Always 2
            // 0 - hash table region
            // 1 - pfs0 region
            regions: [2]extern struct {
                offset: u64,
                size: u64,
            } align(1),
            reserved: [0x80]u8 align(1),
        },

        integrity_meta_info: extern struct {
            magic: u32,
            version: u32,
            master_hash_size: u32,
            info_level_hash: extern struct {
                max_layers: u32,
                levels: [6]extern struct {
                    logical_offset: u64,
                    hash_data_size: u64,
                    block_size_log2: u32,
                    reserved: u32,
                } align(1),
                signature_salt: [0x20]u8 align(1),
            },
            master_hash: [0x20]u8 align(1),
            reserved: [0x18]u8 align(1),
        },

        // TODO: more

        hash_data_raw: [0xf8]u8 align(1),
    },
    patch_info: [0x40]u8 align(1), // TODO: struct
    generation: u32,
    secure_value: u32,
    sparse_info: [0x30]u8 align(1), // TODO: struct
    compression_info: [0x28]u8 align(1), // TODO: struct
    meta_data_hash_data_info: [0x30]u8 align(1), // TODO: struct
    reserved2: [0x30]u8 align(1),
};

const DistributionType = enum(u8) {
    download = 0,
    game_card = 1,
};

const KeyGenerationOld = enum(u8) {
    _1_0_0 = 0,
    unused = 1,
    _3_0_0 = 2,
};

const KeyAreaEncryptionKeyIndex = enum(u8) {
    application = 0,
    ocean = 1,
    system = 2,
};

const KeyGeneration = enum(u8) {
    _3_0_1 = 3,
    _4_0_0 = 4,
    _5_0_0 = 5,
    _6_0_0 = 6,
    _6_2_0 = 7,
    _7_0_0 = 8,
    _8_1_0 = 9,
    _9_0_0 = 10,
    _9_1_0 = 11,
    _12_1_0 = 12,
    _13_0_0 = 13,
    _14_0_0 = 14,
    _15_0_0 = 15,
    _16_0_0 = 16,
    _17_0_0 = 17,
    _18_0_0 = 18,
    _19_0_0 = 19,

    Invalid = 0xff,
};

const fs_block_size = 0x200;
const fs_entry_count = 4;
const ivfc_max_level = 6;

const SectionType = enum {
    code,
    data,
    logo,
};

const Header = extern struct {
    signature0: [0x100]u8 align(1),
    signature1: [0x100]u8 align(1),
    magic: [4]u8 align(1),
    distribution_type: DistributionType,
    content_type: ContentArchiveContentType,
    key_generation_old: KeyGenerationOld,
    key_area_encryption_key_index: KeyAreaEncryptionKeyIndex,
    content_size: u64,
    program_id: u64,
    content_index: u32,
    sdk_addon_version: u32,
    key_generation: KeyGeneration,
    signature_key_generation: u8,
    reserved: [0xe]u8,
    rights_id: [0x10]u8,
    fs_entries: [fs_entry_count]FsEntry align(1),
    // TODO: correct?
    section_hashes: [4][0x20]u8 align(1),
    encrypted_keys: [4][0x10]u8 align(1),
    padding_0x340: [0xc0]u8 align(1),
    fs_headers: [fs_entry_count]FsHeader align(1),

    pub fn getSectionTypeFromIndex(self: *const Header, index: usize) !SectionType {
        if (self.content_type != .program) {
            return .data;
        }

        return switch (index) {
            0 => .code,
            1 => .data,
            2 => .logo,
            else => error.InvalidSectionIndex,
        };
    }
};

pub const ContentArchive = struct {
    content_type: ContentArchiveContentType,
    root_dir: Directory,

    pub fn init(allocator: std.mem.Allocator, keyset: ?crypto.Keyset, encrypted_title_key: ?[0x10]u8, file: *File) !ContentArchive {
        var self: ContentArchive = undefined;
        self.root_dir = try Directory.init(allocator);

        // Keyset
        // TODO: support decrypted NCAs?
        const ks = keyset orelse {
            std.debug.print("Keyset is null\n", .{});
            return error.KeysetIsNull;
        };

        file.setCrypto(crypto.aes.Context.initXts(ks.header_key, 0x200), 0);

        // Reader
        var buffer: [8192]u8 = undefined;
        var reader: FileReader = undefined;
        try file.createReader(&reader, &buffer, 0);

        // Header
        const header = try reader.interface.takeStruct(Header, .little);
        if (!std.mem.eql(u8, &header.magic, "NCA3")) {
            std.debug.print("Invalid NCA magic {s}\n", .{header.magic});
            return error.InvalidNcaMagic;
        }

        self.content_type = header.content_type;

        // Key generation
        var key_gen = @intFromEnum(header.key_generation_old);
        const key_gen_new = @intFromEnum(header.key_generation);
        if (key_gen_new > key_gen) {
            key_gen = key_gen_new;
        }
        if (key_gen != 0) {
            // Key gen 0 and 1 uses the same key
            key_gen -= 1;
        }

        // Rights ID
        var has_rights_id = false;
        for (header.rights_id) |b| {
            if (b != 0x0) {
                has_rights_id = true;
                break;
            }
        }

        // Keys
        var keys_crypto = crypto.aes.ecb.Context.init(ks.key_area_keys[@intFromEnum(header.key_area_encryption_key_index)][key_gen]);
        var keys: [4][0x10]u8 = undefined;

        try keys_crypto.decrypt(@ptrCast(&keys), @ptrCast(&header.encrypted_keys));

        // Key
        var key: [0x10]u8 = undefined;
        if (has_rights_id) {
            // TODO: support decrypted NCAs?
            const enc_title_key = encrypted_title_key orelse {
                std.debug.print("Title key is null\n", .{});
                return error.TitleKeyIsNull;
            };

            var title_crypto = crypto.aes.ecb.Context.init(ks.title_keks[key_gen]);

            try title_crypto.decrypt(&key, &enc_title_key);
            std.debug.print("Title key (decrypted): {x}\n", .{key});
        } else {
            key = keys[2];
        }

        // Entries
        for (0..fs_entry_count) |i| {
            const entry = &header.fs_entries[i];
            const fs_header = &header.fs_headers[i];
            if (entry.start_offset == 0x0) {
                continue;
            }

            // Crypto
            var section_crypto: ?crypto.aes.Context = null;
            switch (fs_header.encryption_type) {
                .none => {},
                .aes_ctr => {
                    var ctr: [0x10]u8 = undefined;
                    for (0..0x8) |j| {
                        // TODO: correct?
                        ctr[j] = @as([*]const u8, @ptrCast(&fs_header.generation))[0x8 - j - 1];
                    }
                    section_crypto = crypto.aes.Context.initCtr(key, ctr);
                },
                else => return error.UnsupportedCryptoType,
            }

            const entry_offset = @as(u64, @intCast(entry.start_offset)) * fs_block_size;
            const section_type = try header.getSectionTypeFromIndex(i);
            switch (section_type) {
                .code, .logo => {
                    if (fs_header.hash_type != .hierarchical_sha256_hash) {
                        std.debug.print("Invalid hash type for section {}\n", .{i});
                        return error.InvalidHashType;
                    }

                    const layer_region = &fs_header.data.hierarchical_sha256_data.regions[1];
                    const file_offset = entry_offset + layer_region.offset;
                    var partition_file = File.initView(file, file_offset, layer_region.size);

                    partition_file.setCrypto(section_crypto, file_offset);

                    const pfs = try PartitionFilesystem.initPfs(allocator, &partition_file);
                    try self.root_dir.addDirectory(if (section_type == .code) "code" else "logo", pfs.root_dir);
                },
                .data => {
                    const level = &fs_header.data.integrity_meta_info.info_level_hash.levels[ivfc_max_level - 1];
                    const file_offset = entry_offset + level.logical_offset;
                    var data_file = File.initView(file, file_offset, level.hash_data_size);
                    try self.root_dir.addFile("data", data_file);

                    data_file.setCrypto(section_crypto, file_offset);

                    try self.root_dir.addFile("data", data_file);
                },
            }
        }

        return self;
    }

    pub fn deinit(self: *ContentArchive) void {
        self.root_dir.deinit();
    }
};
