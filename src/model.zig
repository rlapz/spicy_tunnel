const std = @import("std");
const assert = std.debug.assert;

const util = @import("util.zig");

pub const Request = extern struct {
    // null-terminated string
    server_name: [server_name_size]u8,

    pub const server_name_size = 256;

    // TODO: only accepts ASCII chars
    pub fn validate(self: Request) bool {
        _ = self;
        return true;
    }

    pub fn getServerName(self: Request) []const u8 {
        return util.toSlice(&self.server_name, server_name_size - 1);
    }
};

pub const Response = extern struct {
    code: u8,
    // null-terminated string
    message: [message_size]u8,

    pub const message_size = 255;

    pub const code = struct {
        pub const ACCEPTED = 0;
        pub const REJECTED = 1;
    };

    // convert null-terminated string -> slice string
    pub inline fn getMessage(self: *Response) []const u8 {
        return util.toSlice(&self.message, message_size - 1);
    }

    comptime {
        assert(@sizeOf(Response) == 256);
        assert(@offsetOf(Response, "code") == 0);
        assert(@offsetOf(Response, "message") == 1);
    }
};
