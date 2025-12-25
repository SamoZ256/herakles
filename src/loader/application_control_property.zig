pub const ApplicationTitle = extern struct {
    name: [0x200]u8 align(1),
    author: [0x100]u8 align(1),
};
