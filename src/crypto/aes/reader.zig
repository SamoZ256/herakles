const std = @import("std");
const Context = @import("context.zig").Context;

pub const Reader = struct {
    in: *std.io.Reader,
    ctx: *const Context,
    offset: u64,
    interface: std.io.Reader,

    pub fn init(in: *std.io.Reader, ctx: *const Context, offset: u64, buffer: []u8) Reader {
        return .{
            .in = in,
            .ctx = ctx,
            .offset = offset,
            .interface = .{
                .vtable = &vtable,
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    // TODO: discard and readVec
    const vtable = std.io.Reader.VTable{
        .stream = stream,
    };

    fn stream(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", r));

        // Read
        const data = limit.slice(try w.writableSliceGreedy(1));
        var vec: [1][]u8 = .{data};
        const n = try self.in.readVec(&vec);

        // Decrypt
        self.ctx.decrypt(data[0..n], data[0..n], self.offset) catch return std.io.Reader.StreamError.ReadFailed;

        self.offset += n;
        w.advance(n);
        return n;
    }
};
