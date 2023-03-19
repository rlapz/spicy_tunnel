const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const json = std.json;
const log = std.log;

const model = @import("../model.zig");

const Client = @This();

pub const Config = struct {
    bridge_host: []const u8,
    bridge_port: u16,
    listen_host: []const u8,
    listen_port: u16,
    server_name: []const u8,
};

allocator: mem.Allocator,
config: Config,
is_alive: bool = false,
listen_fd: ?os.socket_t = null,
bridge_fd: ?os.socket_t = null,

pub fn init(allocator: mem.Allocator, config: Config) Client {
    return .{
        .allocator = allocator,
        .config = config,
    };
}

pub fn deinit(self: *Client) void {
    if (self.listen_fd) |fd|
        os.closeSocket(fd);

    if (self.bridge_fd) |fd|
        os.closeSocket(fd);
}

pub fn run(self: *Client) !void {
    if (self.config.server_name.len >= model.Request.server_name_size)
        return error.ServerNameTooLong;
}

//
// private
//
fn setupListener(self: *Client) !void {
    const cfg = &self.config;
    const saddr = try net.Address.parseIp(cfg.listen_port, cfg.listen_port);
    const sfd = try os.socket(saddr.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);

    try os.setsockopt(
        sfd,
        os.SOL.SOCKET,
        os.SO.REUSEADDR,
        &mem.toBytes(@as(c_int, 1)),
    );

    try os.bind(sfd, &saddr.any, saddr.getOsSockLen());
    try os.listen(sfd, 10);

    self.listen_fd = sfd;
}

fn connectToBridge(self: *Client) !void {
    const cfg = &self.config;
    var addr_list = try net.getAddressList(
        self.allocator,
        cfg.bridge_host,
        cfg.bridge_port,
    );

    if (addr_list.addrs.len == 0)
        return error.UnknownHostName;

    for (addr_list) |a| {
        const sfd = os.socket(a.any.family, os.SOCK.STREAM, os.IPPROTO.TCP) catch
            continue;

        os.connect(sfd, &a.any, a.getOsSockLen()) catch
            continue;

        // success
        return sfd;
    }

    return error.ConnectionRefused;
}

fn sendRequest(self: *Client) !void {
    var req: model.Request = undefined;
    req.setServerName(self.config.server_name);
}
