pub const model = struct {
    pub const Request = struct {
        server_name: []const u8,
    };

    pub const Response = struct {
        code: Code,
        message: []const u8,

        pub const Code = enum(u32) {
            ACCEPTED,
            REJECTED,
        };
    };
};
