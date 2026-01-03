pub const crypto = @import("crypto/mod.zig");
pub const fs = @import("fs/mod.zig");
pub const loader = @import("loader/mod.zig");

// TODO: move this to a separate file

const std = @import("std");

fn Slice(comptime T: type, comptime is_const: bool) type {
    return extern struct {
        const Ptr = if (is_const) [*]const T else [*]T;
        const S = if (is_const) []const T else []T;

        ptr: Ptr,
        len: u64,

        pub fn init(s: S) @This() {
            return .{
                .ptr = s.ptr,
                .len = s.len,
            };
        }

        pub fn slice(self: @This()) S {
            return self.ptr[0..self.len];
        }
    };
}

const QueryType = enum(u32) {
    name = 0,
    display_version = 1,
    supported_formats = 2,
};

const StreamAdapter = struct {
    file: *const fs.File,
    reader: fs.FileReader,
    seek: u64,
    size: u64,
};

const StreamInterface = extern struct {
    handle: *anyopaque,
    get_seek: *const fn (stream: *anyopaque) callconv(.c) u64 = getSeek,
    seek_to: *const fn (stream: *anyopaque, seek: u64) callconv(.c) void = seekTo,
    seek_by: *const fn (stream: *anyopaque, offset: u64) callconv(.c) void = seekBy,
    get_size: *const fn (stream: *anyopaque) callconv(.c) u64 = getSize,
    read_raw: *const fn (stream: *anyopaque, buffer: Slice(u8, false)) callconv(.c) void = readRaw,

    fn getSeek(stream: *anyopaque) callconv(.c) u64 {
        const adapter: *StreamAdapter = @ptrCast(@alignCast(stream));
        return adapter.seek;
    }

    fn seekTo(stream: *anyopaque, seek: u64) callconv(.c) void {
        const adapter: *StreamAdapter = @ptrCast(@alignCast(stream));
        if (seek >= adapter.seek) {
            _ = adapter.reader.interface.discard(.limited(seek - adapter.seek)) catch |err| std.debug.panic("Failed to seek to {}: {}", .{ seek, err });
            adapter.seek = seek;
            return;
        }

        adapter.file.createReader(&adapter.reader, adapter.reader.interface.buffer, seek) catch |err| std.debug.panic("Failed to seek to {}: {}", .{ seek, err });
        adapter.seek = seek;
    }

    fn seekBy(stream: *anyopaque, offset: u64) callconv(.c) void {
        const adapter: *StreamAdapter = @ptrCast(@alignCast(stream));
        _ = adapter.reader.interface.discard(.limited(offset)) catch |err| std.debug.panic("Failed to seek by {}: {}", .{ offset, err });
    }

    fn getSize(stream: *anyopaque) callconv(.c) u64 {
        const adapter: *StreamAdapter = @ptrCast(@alignCast(stream));
        return adapter.size;
    }

    fn readRaw(stream: *anyopaque, buffer: Slice(u8, false)) callconv(.c) void {
        const adapter: *StreamAdapter = @ptrCast(@alignCast(stream));
        adapter.reader.interface.readSliceAll(buffer.slice()) catch |err| std.debug.panic("Failed to read data: {}", .{err});
        adapter.seek += buffer.len;
    }
};

const AddFileFnT = fn (self: *anyopaque, path: Slice(u8, true), stream: StreamInterface) callconv(.c) void;

const Context = struct {
    keyset: ?crypto.Keyset,

    pub fn init(self: *Context, options: []const []const u8) error{InvalidKeysetPath}!void {
        // TODO: parse options
        _ = options;

        self.keyset = crypto.Keyset.init("/Volumes/T7/Documents/switch/keys/18.1.0_Keys/prod.keys") catch return error.InvalidKeysetPath; // HACK
    }

    pub fn query(self: *const Context, what: QueryType, buffer: []u8) error{BufferTooSmall}!usize {
        _ = self; // TODO: remove
        const res = switch (what) {
            .name => "Herakles",
            .display_version => "v0.0.1",
            .supported_formats => "nsp", // TODO: only if keyset is valid
        };

        if (buffer.len < res.len) return error.BufferTooSmall;
        @memcpy(buffer[0..res.len], res);
        return res.len;
    }
};

const Loader = struct {
    arena: std.heap.ArenaAllocator,
    file_handle: std.fs.File,
    file_storage: fs.DiskStorage,
    file: fs.File,
    loader: loader.Loader,

    pub fn init(self: *Loader, allocator: std.mem.Allocator, context: *const Context, add_file: *const AddFileFnT, root_dir: *anyopaque, path: []const u8) error{ AllocationFailed, UnsupportedFile }!void {
        self.arena = std.heap.ArenaAllocator.init(allocator);

        // File
        self.file_handle = std.fs.openFileAbsolute(path, .{}) catch unreachable;

        self.file_storage = fs.DiskStorage.init(&self.file_handle);
        self.file = fs.File.initWithDiskStorage(&self.file_storage) catch return error.UnsupportedFile;

        // Loader
        // TODO: support other loaders as well
        self.loader = loader.Loader.initNsp(self.arena.allocator(), &self.file, context.keyset) catch return error.UnsupportedFile;

        // Add to root
        const buffer = self.arena.allocator().alloc(u8, 1024) catch return error.AllocationFailed;
        var iter = self.loader.root_dir.iterator();
        while (iter.next()) |entry| {
            process(self.arena.allocator(), add_file, root_dir, entry.value_ptr, entry.key_ptr.*, buffer) catch return error.AllocationFailed;
        }
    }

    pub fn deinit(self: *Loader) void {
        self.loader.deinit();
        self.file_handle.close();
        self.arena.deinit();
    }

    // Add helpers
    fn processFile(allocator: std.mem.Allocator, add_file: *const AddFileFnT, root_dir: *anyopaque, file: *const fs.File, path: []const u8, buffer: []u8) anyerror!void {
        const adapter = try allocator.create(StreamAdapter);
        adapter.file = file;
        try file.createReader(&adapter.reader, buffer, 0);
        adapter.seek = 0;
        adapter.size = file.size;

        const interface = StreamInterface{
            .handle = adapter,
        };

        add_file(root_dir, Slice(u8, true).init(path), interface);
    }

    fn processDirectory(allocator: std.mem.Allocator, add_file: *const AddFileFnT, root_dir: *anyopaque, dir: *const fs.Directory, path: []const u8, buffer: []u8) anyerror!void {
        var iter = dir.iterator();
        while (iter.next()) |entry| {
            const crnt_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.key_ptr.* });
            try process(allocator, add_file, root_dir, entry.value_ptr, crnt_path, buffer);
        }
    }

    fn process(allocator: std.mem.Allocator, add_file: *const AddFileFnT, root_dir: *anyopaque, entry: *const fs.Entry, path: []const u8, buffer: []u8) anyerror!void {
        switch (entry.*) {
            .file => |*file| try processFile(allocator, add_file, root_dir, file, path, buffer),
            .directory => |*directory| try processDirectory(allocator, add_file, root_dir, directory, path, buffer),
        }
    }
};

fn ReturnValue(comptime Result: type, comptime T: type) type {
    return extern struct {
        res: Result,
        value: T,
    };
}

export fn hydra_ext_get_api_version() u32 {
    return 1;
}

const CreateContextResult = enum(u32) {
    success = 0,
    allocation_failed = 1,
    invalid_options = 2,
};

export fn hydra_ext_create_context(options: Slice(Slice(u8, true), true)) ReturnValue(CreateContextResult, ?*anyopaque) {
    const allocator = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Convert options
    const options_slice = arena.allocator().alloc([]const u8, options.len) catch {
        return .{ .res = .invalid_options, .value = null };
    };
    for (0..options.len) |i| {
        options_slice[i] = options.slice()[i].slice();
    }

    // TODO: use different allocator
    const context_ptr = allocator.create(Context) catch {
        return .{ .res = .allocation_failed, .value = null };
    };
    errdefer std.heap.page_allocator.destroy(context_ptr);
    context_ptr.init(options_slice) catch {
        return .{ .res = .invalid_options, .value = null };
    };
    return .{ .res = .success, .value = @ptrCast(context_ptr) };
}

export fn hydra_ext_destroy_context(context: *Context) void {
    // TODO: use different allocator
    std.heap.page_allocator.destroy(context);
}

const QueryResult = enum(u32) {
    success = 0,
    buffer_too_small = 1,
};

export fn hydra_ext_query(context: *Context, what: QueryType, buffer: Slice(u8, false)) ReturnValue(QueryResult, u64) {
    const ret = context.query(what, buffer.slice()) catch {
        return .{ .res = .buffer_too_small, .value = 0 };
    };
    return .{ .res = .success, .value = @intCast(ret) };
}

const CreateLoaderFromFileResult = enum(u32) {
    success = 0,
    allocation_failed = 1,
    unsupported_file = 2,
};

export fn hydra_ext_create_loader_from_file(context: *Context, add_file: *const AddFileFnT, root_dir: *anyopaque, path: Slice(u8, true)) CreateLoaderFromFileResult {
    // TODO: use different allocator
    const ldr = std.heap.page_allocator.create(Loader) catch return .allocation_failed;
    errdefer std.heap.page_allocator.destroy(ldr);
    ldr.init(std.heap.page_allocator, context, add_file, root_dir, path.slice()) catch |err| {
        return switch (err) {
            error.AllocationFailed => .allocation_failed,
            error.UnsupportedFile => .unsupported_file,
        };
    };
    return .success;
}

export fn hydra_ext_destroy_loader(context: *Context, ldr: *Loader) void {
    _ = context;
    ldr.deinit();
    // TODO: use different allocator
    std.heap.page_allocator.destroy(ldr);
}
