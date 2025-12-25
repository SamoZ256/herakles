const std = @import("std");

pub const Keyset = struct {
    // TODO: all keys
    header_key: [0x20]u8,
    title_keks: [0xe][0x10]u8,
    key_area_keys: [3][0xe][0x10]u8,

    pub fn init(path: []const u8) !Keyset {
        var self: Keyset = undefined;

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        var buffer: [4096]u8 = undefined;
        var reader = file.reader(&buffer);
        while (true) {
            // Name
            var name = try reader.interface.takeDelimiter('=') orelse break;
            while (name[name.len - 1] == ' ') {
                name = name[0 .. name.len - 1];
            }

            // Value
            var value = try reader.interface.takeDelimiter('\n') orelse break;
            while (value[0] == ' ') {
                value = value[1..value.len];
            }

            // TODO: all keys
            if (std.mem.eql(u8, name, "header_key")) {
                _ = try std.fmt.hexToBytes(&self.header_key, value);
            } else if (name.len >= 8 and std.mem.eql(u8, name[0..8], "titlekek")) {
                const index = std.fmt.parseInt(u8, name[9..], 16) catch continue;
                _ = try std.fmt.hexToBytes(&self.title_keks[index], value);
            } else if (name.len >= 12 and std.mem.eql(u8, name[0..12], "key_area_key")) {
                const area_key_type = name[13..];
                if (area_key_type.len >= 11 and std.mem.eql(u8, area_key_type[0..11], "application")) {
                    const index = std.fmt.parseInt(u8, area_key_type[12..], 16) catch continue;
                    _ = try std.fmt.hexToBytes(&self.key_area_keys[0][index], value);
                } else if (area_key_type.len >= 5 and std.mem.eql(u8, area_key_type[0..5], "ocean")) {
                    const index = std.fmt.parseInt(u8, area_key_type[6..], 16) catch continue;
                    _ = try std.fmt.hexToBytes(&self.key_area_keys[1][index], value);
                } else if (area_key_type.len >= 6 and std.mem.eql(u8, area_key_type[0..6], "system")) {
                    const index = std.fmt.parseInt(u8, area_key_type[7..], 16) catch continue;
                    _ = try std.fmt.hexToBytes(&self.key_area_keys[2][index], value);
                } else {
                    std.debug.print("Unknown key area key type: {s}\n", .{area_key_type});
                    return error.UnknownKeyAreaKeyType;
                }
            }
        }

        return self;
    }
};
