const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const json = std.json;
const log = std.log;

const model = @import("../model.zig");
const util = @import("../util.zig");
const snet = @import("../net.zig");

const BUFFER_SIZE = 4096;

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
    const cfg = &self.config;
    if (cfg.server_name.len >= model.Request.server_name_size)
        return error.ServerNameTooLong;

    if (!util.validateServerName(cfg.server_name))
        return error.InvalidServerName;

    self.bridge_fd = try snet.connectToBridge(cfg.bridge_host, cfg.bridge_port);
    try self.sendRequest();
    self.recvResponse() catch |err| {
        log.err("{s}", .{@errorName(err)});
        return;
    };

    log.info("listening on: [{s}:{}] -> \"{s}\"\n", .{
        cfg.listen_host,
        cfg.listen_port,
        cfg.server_name,
    });
    self.listen_fd = try snet.setupListener(cfg.listen_host, cfg.listen_port);
    return self.mainLoop();
}

//
// private
//
fn mainLoop(self: *Client) !void {
    var pfds: [2]os.pollfd = undefined;
    pfds[0].events = os.POLL.IN;
    pfds[1].events = os.POLL.IN;

    const pipe = try os.pipe();
    defer for (pipe) |p|
        os.close(p);

    const cfd = try os.accept(self.listen_fd.?, null, null, os.SOCK.NONBLOCK);
    defer os.close(cfd);

    const bridge_fd = self.bridge_fd.?;
    pfds[0].fd = cfd;
    pfds[1].fd = bridge_fd;

    self.is_alive = true;
    while (self.is_alive) {
        if ((try os.poll(&pfds, 1000)) == 0)
            continue;

        if ((pfds[0].revents & os.POLL.IN) != 0) {
            snet.spipe(cfd, bridge_fd, &pipe, BUFFER_SIZE) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => break,
            };
        }

        if ((pfds[1].revents & os.POLL.IN) != 0) {
            snet.spipe(bridge_fd, cfd, &pipe, BUFFER_SIZE) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => break,
            };
        }
    }
}

fn sendRequest(self: *Client) !void {
    var req: model.Request = undefined;
    var buff = mem.asBytes(&req);

    @memset(buff, 0, @sizeOf(@TypeOf(req)));
    req.setServerName(self.config.server_name);
    req.code = .CLIENT;

    return snet.sendRequest(buff, self.bridge_fd);
}

fn recvResponse(self: *Client) !void {
    var res: model.Response = undefined;
    var buff = mem.asBytes(&res);

    @memset(buff, 0, @sizeOf(@TypeOf(res)));
    try snet.recvResponse(buff, self.bridge_fd);

    log.info("response: {s}\n", .{res.getMessage()});
    return switch (res.code) {
        .ACCEPTED => {},
        .REJECTED => error.Rejected,
        else => error.InvalidResponseCode,
    };
}
