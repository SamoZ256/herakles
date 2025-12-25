const std = @import("std");
const ctr = @import("ctr.zig");
const ecb = @import("ecb.zig");
const xts = @import("xts.zig");

pub const Context = union(enum) {
    ctr: ctr.Context,
    ecb: ecb.Context,
    xts: xts.Context,

    pub fn initCtr(key: [16]u8, counter: [16]u8) Context {
        return .{ .ctr = ctr.Context.init(key, counter) };
    }

    pub fn initEcb(key: [16]u8) Context {
        return .{ .ecb = ecb.Context.init(key) };
    }

    pub fn initXts(key: [32]u8, sector_size: usize) Context {
        return .{ .xts = xts.Context.init(key, sector_size) };
    }

    pub fn encrypt(self: *const Context, dst: []u8, src: []const u8, offset: u64) !void {
        switch (self.*) {
            .ctr => try self.ctr.crypt(dst, src, offset),
            .ecb => try self.ecb.encrypt(dst, src),
            .xts => try self.xts.encrypt(dst, src, offset),
        }
    }

    pub fn decrypt(self: *const Context, dst: []u8, src: []const u8, offset: u64) !void {
        switch (self.*) {
            .ctr => try self.ctr.crypt(dst, src, offset),
            .ecb => try self.ecb.decrypt(dst, src),
            .xts => try self.xts.decrypt(dst, src, offset),
        }
    }
};
