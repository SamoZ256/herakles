const std = @import("std");
const OwnedStringMap = @import("../common/owned_string_map.zig").OwnedStringMap;
const File = @import("file.zig").File;

pub const Entry = union(enum) {
    file: File,
    directory: Directory,

    pub fn asFile(self: *Entry) ?*File {
        return switch (self.*) {
            .file => |*file| file,
            else => null,
        };
    }

    pub fn asDirectory(self: *Entry) ?*Directory {
        return switch (self.*) {
            .directory => |*directory| directory,
            else => null,
        };
    }

    pub fn save(self: *const Entry, allocator: std.mem.Allocator, path: []const u8) anyerror!void {
        switch (self.*) {
            .file => |*file| try file.save(path),
            .directory => |*directory| try directory.save(allocator, path),
        }
    }

    fn formatImpl(self: *const Entry, writer: *std.io.Writer, indent: usize) std.io.Writer.Error!void {
        switch (self.*) {
            .file => |*file| try file.format(writer),
            .directory => |*directory| try directory.formatImpl(writer, indent),
        }
    }

    pub fn format(self: *const Entry, writer: *std.io.Writer) std.io.Writer.Error!void {
        try self.formatImpl(writer, 0);
    }
};

pub const Directory = struct {
    allocator: std.mem.Allocator,
    entries: OwnedStringMap(Entry),

    pub fn init(allocator: std.mem.Allocator) !Directory {
        var self: Directory = undefined;
        self.allocator = allocator;
        self.entries = OwnedStringMap(Entry).init(allocator);

        return self;
    }

    pub fn deinit(self: *Directory) void {
        // TODO: deinit individual entries?
        self.entries.deinit();
    }

    fn addEntry(self: *Directory, name: []const u8, entry: Entry) !void {
        _ = try self.entries.put(name, entry);
    }

    pub fn addFile(self: *Directory, name: []const u8, file: File) !void {
        try self.addEntry(name, .{ .file = file });
    }

    pub fn addDirectory(self: *Directory, name: []const u8, directory: Directory) !void {
        try self.addEntry(name, .{ .directory = directory });
    }

    pub fn iterator(self: *const Directory) std.StringHashMap(Entry).Iterator {
        return self.entries.iterator();
    }

    pub fn getEntry(self: *const Directory, name: []const u8) !*Entry {
        return self.entries.getPtr(name) orelse error.EntryDoesNotExist;
    }

    pub fn getFile(self: *const Directory, name: []const u8) !*File {
        const entry = try self.getEntry(name);
        return switch (entry.*) {
            .file => |*file| file,
            else => error.EntryNotAFile,
        };
    }

    pub fn getDirectory(self: *const Directory, name: []const u8) !*Directory {
        const entry = try self.getEntry(name);
        return switch (entry.*) {
            .directory => |*directory| directory,
            else => error.EntryNotADirectory,
        };
    }

    pub fn save(self: *const Directory, allocator: std.mem.Allocator, path: []const u8) anyerror!void {
        // Create directory
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Entries
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const crnt_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.key_ptr.* });
            defer allocator.free(crnt_path);

            try entry.value_ptr.save(allocator, crnt_path);
        }
    }

    fn formatImpl(self: *const Directory, writer: *std.io.Writer, indent: usize) std.io.Writer.Error!void {
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const is_file = entry.value_ptr.asFile() != null;

            // TODO: is there a better way?
            for (0..indent) |_| {
                try writer.print("  ", .{});
            }

            try writer.print("{c} {s}{c}", .{ if (is_file) @as(u8, '-') else '+', entry.key_ptr.*, if (is_file) @as(u8, ' ') else '\n' });
            try entry.value_ptr.formatImpl(writer, indent + 1);
            if (is_file) {
                try writer.print("\n", .{});
            }
        }
    }

    pub fn format(self: *const Directory, writer: *std.io.Writer) std.io.Writer.Error!void {
        try self.formatImpl(writer, 0);
    }
};
