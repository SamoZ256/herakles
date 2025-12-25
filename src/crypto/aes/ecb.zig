const std = @import("std");
const aes = std.crypto.core.aes;

// TODO: support unaligned prefix and suffix
pub const Context = struct {
    enc: aes.AesEncryptCtx(aes.Aes128),
    dec: aes.AesDecryptCtx(aes.Aes128),

    pub fn init(key: [16]u8) Context {
        return Context{
            .enc = aes.Aes128.initEnc(key),
            .dec = aes.Aes128.initDec(key),
        };
    }

    pub fn encrypt(self: *const Context, dst: []u8, src: []const u8) !void {
        if (dst.len != src.len)
            return error.LengthMismatch;
        if (src.len % 16 != 0)
            return error.InvalidLength;

        var i: usize = 0;
        while (i < src.len) : (i += 16) {
            self.enc.encrypt(@as(*[16]u8, @ptrCast(dst[i .. i + 16])), @as(*const [16]u8, @ptrCast(src[i .. i + 16])));
        }
    }

    pub fn decrypt(self: *const Context, dst: []u8, src: []const u8) !void {
        if (dst.len != src.len)
            return error.LengthMismatch;
        if (src.len % 16 != 0)
            return error.InvalidLength;

        var i: usize = 0;
        while (i < src.len) : (i += 16) {
            self.dec.decrypt(@as(*[16]u8, @ptrCast(dst[i .. i + 16])), @as(*const [16]u8, @ptrCast(src[i .. i + 16])));
        }
    }
};
