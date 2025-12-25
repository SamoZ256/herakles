const std = @import("std");
const argsParser = @import("args");
const herakles = @import("herakles");

pub fn main() !void {
    // Allocator
    // TODO: use different allocator
    const allocator = std.heap.page_allocator;

    // Args
    const options = argsParser.parseForCurrentProcess(struct {
        keyset: ?[]const u8 = null,
        output: ?[]const u8 = null,

        pub const shorthands = .{
            .k = "keyset",
            .o = "output",
        };
    }, allocator, .print) catch return error.InvalidArguments;
    defer options.deinit();

    if (options.positionals.len != 1) {
        // TODO: handle this better
        std.debug.print("Invalid count of positional arguments\n", .{});
        return error.InvalidArguments;
    }

    // Keyset
    const keyset: ?herakles.crypto.Keyset = if (options.options.keyset) |keyset_path| try herakles.crypto.Keyset.init(keyset_path) else null;

    // File
    const file_handle = try std.fs.openFileAbsolute(options.positionals[0], .{});
    defer file_handle.close();

    const file_storage = herakles.fs.DiskStorage.init(&file_handle);
    const file = try herakles.fs.File.initWithDiskStorage(&file_storage);

    // Loader
    var loader = try herakles.loader.Loader.initNsp(allocator, &file, keyset);
    defer loader.deinit();

    // Print
    std.debug.print("{f}", .{loader.root_dir});

    // Save
    if (options.options.output) |output| {
        try loader.save(allocator, output);
    }
}
