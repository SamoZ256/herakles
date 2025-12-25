// This file is a port of AES-XTS from hactool (https://github.com/SciresM/hactool)

const std = @import("std");
const aes = std.crypto.core.aes;

// Nintendo LE tweak generator
fn getTweak(out: *[16]u8, sector: usize) void {
    var s = sector;
    var i: i32 = 15;
    while (i >= 0) : (i -= 1) {
        out[@intCast(i)] = @truncate(s);
        s >>= 8;
    }
}

/// GF(2^128) multiply-by-x
fn gfMulX(tweak: *[16]u8) void {
    var carry: u8 = 0;
    var i: usize = 0;

    while (i < 16) : (i += 1) {
        const v = tweak[i];
        tweak[i] = (v << 1) | carry;
        carry = (v >> 7) & 1;
    }

    if (carry != 0) {
        tweak[0] ^= 0x87;
    }
}

pub const Context = struct {
    data_key_enc: aes.AesEncryptCtx(aes.Aes128),
    data_key_dec: aes.AesDecryptCtx(aes.Aes128),
    tweak_key: aes.AesEncryptCtx(aes.Aes128),
    sector_size: usize,

    pub fn init(key: [32]u8, sector_size: usize) Context {
        var dk: [16]u8 = undefined;
        var tk: [16]u8 = undefined;

        @memcpy(&dk, key[0..16]);
        @memcpy(&tk, key[16..32]);

        return Context{
            .data_key_enc = aes.Aes128.initEnc(dk),
            .data_key_dec = aes.Aes128.initDec(dk),
            .tweak_key = aes.Aes128.initEnc(tk),
            .sector_size = sector_size,
        };
    }

    fn cryptSector(self: *const Context, dst: []u8, src: []const u8, tweak: *const [16]u8, dec: bool) void {
        var tweak_block: [16]u8 = undefined;
        self.tweak_key.encrypt(&tweak_block, tweak);

        var i: usize = 0;
        while (i < src.len) : (i += 16) {
            var block: [16]u8 = undefined;
            var xored: [16]u8 = undefined;

            @memcpy(&block, src[i .. i + 16]);

            // P ^ T
            for (0..16) |j|
                xored[j] = block[j] ^ tweak_block[j];

            if (dec) {
                self.data_key_dec.decrypt(&xored, &xored);
            } else {
                self.data_key_enc.encrypt(&xored, &xored);
            }

            // C ^ T
            for (0..16) |j|
                dst[i + j] = xored[j] ^ tweak_block[j];

            gfMulX(&tweak_block);
        }
    }

    // TODO: support unaligned prefix and suffix
    fn crypt(self: *const Context, dst: []u8, src: []const u8, offset: u64, dec: bool) !void {
        if (dst.len != src.len)
            return error.LengthMismatch;
        if (dst.len % self.sector_size != 0)
            return error.InvalidLength;
        if (offset % self.sector_size != 0)
            return error.InvalidOffset;

        var sector = offset / self.sector_size;
        var tweak: [16]u8 = undefined;

        var off: u64 = 0;
        while (off < src.len) : (off += self.sector_size) {
            getTweak(&tweak, sector);
            sector += 1;

            self.cryptSector(dst[off .. off + self.sector_size], src[off .. off + self.sector_size], &tweak, dec);
        }
    }

    pub fn encrypt(self: *const Context, dst: []u8, src: []const u8, offset: u64) !void {
        try self.crypt(dst, src, offset, false);
    }

    pub fn decrypt(self: *const Context, dst: []u8, src: []const u8, offset: u64) !void {
        try self.crypt(dst, src, offset, true);
    }
};
