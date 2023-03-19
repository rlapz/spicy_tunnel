const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const json = std.json;
const log = std.log;

const model = @import("../model.zig");
const util = @import("../util.zig");
const snet = @import("../net.zig");
const req_code = model.Request.code;
const res_code = model.Response.code;

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
    _ = self;
}

fn sendRequest(self: *Client) !void {
    var req: model.Request = undefined;
    var buff = mem.asBytes(&req);

    @memset(buff, 0, @sizeOf(@TypeOf(req)));
    req.setServerName(self.config.server_name);
    req.code = req_code.CLIENT;

    return snet.sendRequest(buff, self.bridge_fd);
}

fn recvResponse(self: *Client) !void {
    var res: model.Response = undefined;
    var buff = mem.asBytes(&res);

    @memset(buff, 0, @sizeOf(@TypeOf(res)));
    try snet.recvResponse(buff, self.bridge_fd);

    log.info("response: {s}\n", .{res.getMessage()});
    return switch (res.code) {
        res_code.ACCEPTED => {},
        res_code.REJECTED => error.Rejected,
        else => error.InvalidResponseCode,
    };
}
