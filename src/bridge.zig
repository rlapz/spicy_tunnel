const std = @import("std");
const mem = std.mem;
const os = std.os;
const io = std.io;

pub const Config = struct {
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 8001,
};

const Bridge = struct {
    allocator: mem.Allocator,
    is_alive: bool = false,
    config: Config,

    fn init(allocator: mem.Allocator, config: Config) Bridge {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    fn deinit(self: *Bridge) void {
        _ = self;
    }
};

//
// Endpoint
//
var bridge_g: *Bridge = undefined;
pub fn run(config: Config) !void {
    _ = config;
}

// private
fn intrHandler(sig: c_int) callconv(.C) void {
    _ = sig;
}

test "bridge run" {}
