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

const OptionType = enum(u32) {
    boolean = 0,
    integer = 1,
    enumeration = 2,
    string = 3,
    path = 4,
};

const OptionConfig = extern struct {
    name: Slice(u8, true),
    description: Slice(u8, true),
    type: OptionType,
    is_required: bool,
    data: extern union {
        enum_value_names: Slice(u8, true),
        path_content_types: Slice(u8, true),
    },
};

const name = "Herakles";
const display_version = "v0.0.1";
const supported_formats = "nsp,xci";

const keyset_path_option_name = "keyset path";
const keyset_path_option_description = "A path to the prod.keys file";
const keyset_path_option_content_types = "file.keys";
const keyset_path_option = OptionConfig{
    .name = Slice(u8, true).init(keyset_path_option_name[0..]),
    .description = Slice(u8, true).init(keyset_path_option_description[0..]),
    .type = .path,
    .is_required = true, // TODO: make non-mandatory
    .data = .{
        .path_content_types = Slice(u8, true).init(keyset_path_option_content_types[0..]),
    },
};
const option_configs = [_]OptionConfig{keyset_path_option};

const Context = struct {
    keyset: ?crypto.Keyset,

    const Option = extern struct {
        key: Slice(u8, true),
        value: Slice(u8, true),
    };

    pub fn init(self: *Context, options: []const Option) error{ InvalidOption, DuplicateOption, InvalidKeysetPath }!void {
        var keyset_path: ?[]const u8 = null;
        for (options) |opt| {
            if (std.mem.eql(u8, opt.key.slice(), keyset_path_option_name)) {
                if (keyset_path) |_| return error.DuplicateOption;
                keyset_path = opt.value.slice();
            } else {
                return error.InvalidOption;
            }
        }

        if (keyset_path) |keyset_p| {
            self.keyset = crypto.Keyset.init(keyset_p) catch return error.InvalidKeysetPath;
        } else {
            self.keyset = null;
        }
    }
};

const StreamAdapter = struct {
    file: *FileAdapter,
    reader: fs.FileReader,
    seek: u64,
};

const FileAdapter = struct {
    loader: *Loader,
    file: *const fs.File,
    allocator: std.heap.FixedBufferAllocator,
    shared_buffer: []u8,

    pub fn init(self: *FileAdapter, ldr: *Loader, allocator: std.mem.Allocator, file: *const fs.File, shared_buffer: []u8) !void {
        self.loader = ldr;
        self.file = file;
        self.allocator = std.heap.FixedBufferAllocator.init(try allocator.alloc(u8, 1024));
        self.shared_buffer = shared_buffer;
    }
};

const AddFileFnT = fn (hydra_context: *anyopaque, self: *anyopaque, path: Slice(u8, true), file: *FileAdapter) callconv(.c) void;

const Loader = struct {
    arena: std.heap.ArenaAllocator,
    file_handle: std.fs.File,
    file_storage: fs.DiskStorage,
    file: fs.File,
    loader: loader.Loader,

    pub fn init(self: *Loader, allocator: std.mem.Allocator, context: *const Context, hydra_context: *anyopaque, add_file: *const AddFileFnT, root_dir: *anyopaque, path: []const u8) error{ AllocationFailed, UnsupportedFile }!void {
        self.arena = std.heap.ArenaAllocator.init(allocator);

        // File
        self.file_handle = std.fs.openFileAbsolute(path, .{}) catch unreachable;

        self.file_storage = fs.DiskStorage.init(&self.file_handle);
        self.file = fs.File.initWithDiskStorage(&self.file_storage) catch return error.UnsupportedFile;

        // Loader
        const extension = std.fs.path.extension(path);
        self.loader = (if (std.mem.eql(u8, extension, ".nsp")) loader.Loader.initNsp(self.arena.allocator(), &self.file, context.keyset, false) else if (std.mem.eql(u8, extension, ".xci")) loader.Loader.initXci(self.arena.allocator(), &self.file, context.keyset, false) else std.debug.panic("Invalid file extension \"{s}\"\n", .{extension})) catch return error.UnsupportedFile;

        // Add to root
        const shared_buffer = self.arena.allocator().alloc(u8, 1024) catch return error.AllocationFailed;
        var iter = self.loader.root_dir.iterator();
        while (iter.next()) |entry| {
            self.process(hydra_context, add_file, root_dir, entry.value_ptr, entry.key_ptr.*, shared_buffer) catch return error.AllocationFailed;
        }
    }

    pub fn deinit(self: *Loader) void {
        self.loader.deinit();
        self.file_handle.close();
        self.arena.deinit();
    }

    // Add helpers
    fn processFile(self: *Loader, hydra_context: *anyopaque, add_file: *const AddFileFnT, root_dir: *anyopaque, file: *const fs.File, path: []const u8, shared_buffer: []u8) anyerror!void {
        const adapter = try self.arena.allocator().create(FileAdapter);
        try adapter.init(self, self.arena.allocator(), file, shared_buffer);

        add_file(hydra_context, root_dir, Slice(u8, true).init(path), adapter);
    }

    fn processDirectory(self: *Loader, hydra_context: *anyopaque, add_file: *const AddFileFnT, root_dir: *anyopaque, dir: *const fs.Directory, path: []const u8, shared_buffer: []u8) anyerror!void {
        var iter = dir.iterator();
        while (iter.next()) |entry| {
            const crnt_path = try std.fs.path.join(self.arena.allocator(), &[_][]const u8{ path, entry.key_ptr.* });
            try self.process(hydra_context, add_file, root_dir, entry.value_ptr, crnt_path, shared_buffer);
        }
    }

    fn process(self: *Loader, hydra_context: *anyopaque, add_file: *const AddFileFnT, root_dir: *anyopaque, entry: *const fs.Entry, path: []const u8, shared_buffer: []u8) anyerror!void {
        switch (entry.*) {
            .file => |*file| try self.processFile(hydra_context, add_file, root_dir, file, path, shared_buffer),
            .directory => |*directory| try self.processDirectory(hydra_context, add_file, root_dir, directory, path, shared_buffer),
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

const QueryType = enum(u32) {
    name = 0,
    display_version = 1,
    supported_formats = 2,
    option_configs = 3,
};

export fn hydra_ext_query(what: QueryType) Slice(u8, true) {
    const res = switch (what) {
        .name => name[0..],
        .display_version => display_version[0..],
        .supported_formats => supported_formats[0..],
        .option_configs => @as([]const u8, @ptrCast(&option_configs)),
    };

    return Slice(u8, true).init(res);
}

const CreateContextResult = enum(u32) {
    success = 0,
    allocation_failed = 1,
    invalid_option = 2,
};

export fn hydra_ext_create_context(options: Slice(Context.Option, true)) ReturnValue(CreateContextResult, ?*anyopaque) {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const context_ptr = std.heap.smp_allocator.create(Context) catch {
        return .{ .res = .allocation_failed, .value = null };
    };
    errdefer std.heap.smp_allocator.destroy(context_ptr);
    context_ptr.init(options.slice()) catch {
        return .{ .res = .invalid_option, .value = null };
    };
    return .{ .res = .success, .value = @ptrCast(context_ptr) };
}

export fn hydra_ext_destroy_context(context: *Context) void {
    std.heap.smp_allocator.destroy(context);
}

const CreateLoaderFromFileResult = enum(u32) {
    success = 0,
    allocation_failed = 1,
    unsupported_file = 2,
};

export fn hydra_ext_create_loader_from_file(context: *Context, hydra_context: *anyopaque, add_file: *const AddFileFnT, root_dir: *anyopaque, path: Slice(u8, true)) CreateLoaderFromFileResult {
    const ldr = std.heap.smp_allocator.create(Loader) catch return .allocation_failed;
    errdefer std.heap.smp_allocator.destroy(ldr);
    ldr.init(std.heap.smp_allocator, context, hydra_context, add_file, root_dir, path.slice()) catch |err| {
        return switch (err) {
            error.AllocationFailed => .allocation_failed,
            error.UnsupportedFile => .unsupported_file,
        };
    };
    return .success;
}

export fn hydra_ext_loader_destroy(context: *Context, ldr: *Loader) void {
    _ = context;
    ldr.deinit();
    std.heap.smp_allocator.destroy(ldr);
}

export fn hydra_ext_file_destroy(file: *FileAdapter) void {
    file.loader.arena.allocator().destroy(file);
}

export fn hydra_ext_file_open(file: *FileAdapter) *StreamAdapter {
    const adapter = file.allocator.allocator().create(StreamAdapter) catch std.debug.panic("Failed to allocate memory", .{});
    adapter.file = file;
    file.file.createReader(&adapter.reader, file.shared_buffer, 0) catch std.debug.panic("Failed to create reader", .{});
    adapter.seek = 0;

    return adapter;
}

export fn hydra_ext_file_get_size(file: *FileAdapter) u64 {
    return file.file.size;
}

export fn hydra_ext_stream_destroy(stream: *StreamAdapter) void {
    stream.file.allocator.allocator().destroy(stream);
}

export fn hydra_ext_stream_get_seek(stream: *StreamAdapter) u64 {
    return stream.seek;
}

export fn hydra_ext_stream_seek_to(stream: *StreamAdapter, seek: u64) void {
    if (seek >= stream.seek) {
        _ = stream.reader.interface.discard(.limited(seek - stream.seek)) catch |err| std.debug.panic("Failed to seek to {}: {}", .{ seek, err });
        stream.seek = seek;
        return;
    }

    stream.file.file.createReader(&stream.reader, stream.reader.interface.buffer, seek) catch |err| std.debug.panic("Failed to seek to {}: {}", .{ seek, err });
    stream.seek = seek;
}

export fn hydra_ext_stream_seek_by(stream: *StreamAdapter, offset: u64) void {
    _ = stream.reader.interface.discard(.limited(offset)) catch |err| std.debug.panic("Failed to seek by {}: {}", .{ offset, err });
}

export fn hydra_ext_stream_get_size(stream: *StreamAdapter) u64 {
    return stream.file.file.size;
}

export fn hydra_ext_stream_read_raw(stream: *StreamAdapter, buffer: Slice(u8, false)) void {
    _ = stream.reader.interface.readSliceAll(buffer.slice()) catch |err| std.debug.panic("Failed to read data: {}", .{err});
    stream.seek += buffer.len;
}
