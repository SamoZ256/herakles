const std = @import("std");
const crypto = @import("../crypto/mod.zig");

pub const FileReader = struct {
    pub const Base = union(enum) {
        disk: std.fs.File.Reader,
        memory: std.io.Reader,

        pub fn interface(self: *@This()) *std.io.Reader {
            return switch (self.*) {
                .disk => |*disk| &disk.interface,
                .memory => |*memory| memory,
            };
        }

        pub fn setInitialSeek(self: *@This(), offset: u64) !void {
            return switch (self.*) {
                .disk => |*disk| try disk.seekTo(offset),
                .memory => |*memory| _ = try memory.discard(.limited(offset)),
            };
        }
    };

    base: Base,
    crypto_reader: ?crypto.aes.Reader,
    interface: *std.io.Reader,
};
