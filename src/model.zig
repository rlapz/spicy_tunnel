pub const Request = struct {
    server_name: []const u8,
};

pub const Response = struct {
    code: i64,
    message: []const u8,

    pub const code = struct {
        pub const ACCEPTED = 0;
        pub const REJECTED = 1;
    };
};
