const std = @import("std");
const mem = std.mem;
const log = std.log;

const util = @import("util.zig");
const Client = @import("client/Client.zig");

pub const Args = Client.Args;

var client_g: *Client = undefined;

pub fn run(args: Args) !void {
    var cl = Client.init(std.heap.page_allocator, args);
    defer cl.deinit();

    client_g = &cl;
    try util.setSignalHandler(intrHandler);

    return cl.run();
}

// private
fn intrHandler(sig: c_int) callconv(.C) void {
    log.err("Interrupted: {}", .{sig});

    client_g.is_alive = false;
}

test "client run" {}
