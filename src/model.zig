const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const util = @import("util.zig");

pub const Request = extern struct {
    code: Code,
    // null-terminated string
    server_name: [server_name_size]u8,

    pub const server_name_size = 255;

    pub const Code = enum(u8) {
        SERVER,
        CLIENT,
        _,
    };

    pub inline fn getServerName(self: Request) []const u8 {
        return util.toSlice(&self.server_name, server_name_size - 1);
    }

    // Only accepts ASCII and Alphanumeric
    pub inline fn setServerName(self: *Request, name: []const u8) void {
        mem.copy(u8, &self.server_name, name);
        self.server_name[name.len] = '\x00';
    }

    //
    // assertions
    //
    comptime {
        assert(@sizeOf(Request) == 256);
        assert(@offsetOf(Request, "code") == 0);
        assert(@offsetOf(Request, "server_name") == 1);
    }
};

pub const Response = extern struct {
    code: Code,
    // null-terminated string
    message: [message_size]u8,

    pub const message_size = 255;

    pub const Code = enum(u8) {
        ACCEPTED,
        REJECTED,
        _,
    };

    // convert null-terminated string -> slice string
    pub inline fn getMessage(self: *Response) []const u8 {
        return util.toSlice(&self.message, message_size - 1);
    }

    pub inline fn setMessage(self: *Response, msg: []const u8) void {
        mem.copy(u8, &self.message, msg);
        self.message[msg.len] = '\x00';
    }

    //
    // assertions
    //
    comptime {
        assert(@sizeOf(Response) == 256);
        assert(@offsetOf(Response, "code") == 0);
        assert(@offsetOf(Response, "message") == 1);
    }
};

//
// unit test
//
test "Request" {
    const name = "hello world!";

    var r: Request = undefined;
    r.setServerName(name);

    assert(mem.eql(u8, name, r.getServerName()));
}

test "Response" {
    const msg = "Failed!!";

    var r: Response = undefined;
    r.setMessage(msg);

    assert(mem.eql(u8, msg, r.getMessage()));
}
