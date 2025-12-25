const std = @import("std");
const aes = std.crypto.core.aes;

pub const Context = struct {
    enc: aes.AesEncryptCtx(aes.Aes128),
    counter: [16]u8,

    pub fn init(key: [16]u8, counter: [16]u8) Context {
        return Context{
            .enc = aes.Aes128.initEnc(key),
            .counter = counter,
        };
    }

    pub fn crypt(self: *const Context, dst: []u8, src: []const u8, offset: u64) !void {
        if (dst.len != src.len)
            return error.LengthMismatch;

        // Initialize the counter
        var ctr = self.counter;
        var off = offset / 16;
        for (0..8) |i| {
            ctr[16 - i - 1] = @intCast(off & 0xff);
            off >>= 8;
        }

        // Handle unaligned prefix
        const byte_offset = offset % 16;
        var i: usize = 0;
        if (byte_offset != 0 and dst.len > 0) {
            var keystream: [16]u8 = undefined;
            self.enc.encrypt(&keystream, &ctr);

            const n = @min(dst.len, 16 - byte_offset);
            for (0..n) |j| {
                dst[j] = src[j] ^ keystream[byte_offset + j];
            }

            i += n;

            // Increment counter
            for (0..8) |j| {
                const index = 16 - j - 1;
                ctr[index] += 1;
                if (ctr[index] != 0) break;
            }
        }

        // Handle remaining aligned bytes
        if (i < dst.len) {
            std.crypto.core.modes.ctr(aes.AesEncryptCtx(aes.Aes128), self.enc, dst[i..], src[i..], ctr, .big);
        }
    }
};
