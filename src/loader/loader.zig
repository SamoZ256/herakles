const std = @import("std");
const crypto = @import("../crypto/mod.zig");
const fs = @import("../fs/mod.zig");
const ApplicationTitle = @import("application_control_property.zig").ApplicationTitle;

pub const Loader = struct {
    arena: std.heap.ArenaAllocator,
    root_dir: fs.Directory,

    pub fn initNsp(allocator: std.mem.Allocator, file: *const fs.File, keyset: ?crypto.Keyset) !Loader {
        var self: Loader = undefined;
        self.arena = std.heap.ArenaAllocator.init(allocator);

        // Partition filesystem
        var pfs = try fs.PartitionFilesystem.initPfs(allocator, file);
        defer pfs.deinit();

        // Title key
        // TODO: handle this after the title ID is known
        var title_key: ?[0x10]u8 = null;
        var iter = pfs.root_dir.iterator();
        while (iter.next()) |entry| {
            if (!std.mem.endsWith(u8, entry.key_ptr.*, ".tik")) {
                continue;
            }

            const tik_file = entry.value_ptr.asFile() orelse return error.InvalidTikFile;

            var buffer: [512]u8 = undefined;
            var reader: fs.FileReader = undefined;
            try tik_file.createReader(&reader, &buffer, 0x180);
            title_key = (try reader.interface.takeArray(0x10)).*;
            std.debug.print("Title key (encrypted): {x}\n", .{title_key.?});
        }

        // NCAs
        var program_nca: ?fs.ContentArchive = null;
        var control_nca: ?fs.ContentArchive = null;
        iter = pfs.root_dir.iterator();
        while (iter.next()) |entry| {
            if (!std.mem.endsWith(u8, entry.key_ptr.*, ".nca")) {
                continue;
            }

            const nca_file = entry.value_ptr.asFile() orelse return error.InvalidPfsContents;
            var content_archive = try fs.ContentArchive.init(allocator, keyset, title_key, nca_file);
            switch (content_archive.content_type) {
                .program => program_nca = content_archive,
                .control => control_nca = content_archive,
                else => content_archive.deinit(),
            }
        }

        // Verify
        var program_nca_ = program_nca orelse return error.MissingProgramNca;
        errdefer program_nca_.deinit();
        var control_nca_ = control_nca orelse return error.MissingControlNca;
        errdefer control_nca_.deinit();

        // Game directory
        var game_dir = try fs.Directory.init(allocator);
        errdefer game_dir.deinit();

        // ExeFS
        const exefs = try program_nca_.root_dir.getDirectory("code");
        try game_dir.addDirectory("exefs", exefs.*);

        // Loading screen
        const loading_screen = try program_nca_.root_dir.getDirectory("logo");
        try game_dir.addDirectory("loading_screen", loading_screen.*);

        // RomFS
        var romfs = try fs.RomFS.init(allocator, try program_nca_.root_dir.getFile("data"));
        errdefer romfs.deinit();

        try game_dir.addDirectory("romfs", romfs.root_dir);

        // Meta
        var meta = try fs.RomFS.init(allocator, try control_nca_.root_dir.getFile("data"));
        errdefer meta.deinit();

        var meta_dir = try fs.Directory.init(allocator);
        errdefer meta_dir.deinit();

        // control.nacp
        const nacp = try meta.root_dir.getFile("control.nacp");
        try meta_dir.addFile("control.nacp", nacp.*);

        // Icons
        var icons = try fs.Directory.init(allocator);
        errdefer icons.deinit();

        iter = meta.root_dir.iterator();
        while (iter.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, "icon"))
                continue;

            const dat_name = entry.key_ptr.*[5..];
            var buffer: [256]u8 = undefined;
            const filename = try std.fmt.bufPrint(&buffer, "{s}.jpg", .{dat_name[0 .. dat_name.len - 4]});

            try icons.addFile(filename, (entry.value_ptr.asFile() orelse return error.IconNotAFile).*);
        }

        try meta_dir.addDirectory("icons", icons);

        try game_dir.addDirectory("meta", meta_dir);

        // Get title name

        // We only need to read the American ENglish title name from the NACP
        var buffer: [1024]u8 = undefined;
        var nacp_reader: fs.FileReader = undefined;
        try nacp.createReader(&nacp_reader, &buffer, 0);

        const title = try nacp_reader.interface.takeStruct(ApplicationTitle, .little);

        // Root directory
        self.root_dir = try fs.Directory.init(allocator);
        errdefer self.root_dir.deinit();

        try self.root_dir.addDirectory(title.name[0 .. std.mem.indexOfScalar(u8, &title.name, 0) orelse title.name.len], game_dir);

        return self;
    }

    pub fn deinit(self: *Loader) void {
        self.root_dir.deinit();
        self.arena.deinit();
    }

    pub fn save(self: *const Loader, allocator: std.mem.Allocator, path: []const u8) !void {
        var save_allocator = std.heap.ArenaAllocator.init(allocator);
        defer save_allocator.deinit();

        try self.root_dir.save(save_allocator.allocator(), path);
    }
};
