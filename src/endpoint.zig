const std = @import("std");
const mem = std.mem;
const os = std.os;
const log = std.log;

const model = @import("model.zig");
const util = @import("util.zig");
const snet = @import("net.zig");

pub const Config = struct {
    general_host: []const u8 = "127.0.0.1",
    general_port: u16 = 8002,
    bridge_host: []const u8,
    bridge_port: u16,
    server_name: []const u8,
    buffer_size: usize = 4096,
    endpoint_type: model.Request.Code,
};

const Endpoint = struct {
    allocator: mem.Allocator,
    config: Config,
    is_alive: bool = false,
    listen_fd: ?os.socket_t = null,
    socket_fd: ?os.socket_t = null,
    bridge_fd: ?os.socket_t = null,

    fn init(allocator: mem.Allocator, config: Config) Endpoint {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    fn deinit(self: *Endpoint) void {
        if (self.socket_fd) |fd|
            os.closeSocket(fd);

        if (self.bridge_fd) |fd|
            os.closeSocket(fd);

        if (self.listen_fd) |fd|
            os.closeSocket(fd);
    }

    fn runServer(self: *Endpoint) !void {
        const cfg = &self.config;

        util.validateServerName(cfg.server_name) catch |err| {
            log.err("server name: {s}", .{@errorName(err)});
            return;
        };

        self.socket_fd = try snet.connectTo(
            self.allocator,
            cfg.general_host,
            cfg.general_port,
        );

        log.info("registering \"{s}\"...", .{cfg.server_name});
        self.bridge_fd = try snet.connectTo(
            self.allocator,
            cfg.bridge_host,
            cfg.bridge_port,
        );

        try self.sendRequest();

        self.recvResponse() catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        };

        self.is_alive = true;
        return self.forward();
    }

    fn runClient(self: *Endpoint) !void {
        const cfg = &self.config;

        util.validateServerName(cfg.server_name) catch |err| {
            log.err("server name: {s}", .{@errorName(err)});
            return;
        };

        log.info("connecting \"{s}\"...", .{cfg.server_name});

        self.bridge_fd = try snet.connectTo(
            self.allocator,
            cfg.bridge_host,
            cfg.bridge_port,
        );

        try self.sendRequest();

        self.recvResponse() catch |err| {
            log.err("{s}", .{@errorName(err)});
            return;
        };

        log.info("listening on: [{s}:{}] -> \"{s}\"", .{
            cfg.general_host,
            cfg.general_port,
            cfg.server_name,
        });

        const lfd = try snet.setupListener(cfg.general_host, cfg.general_port);
        self.listen_fd = lfd;

        self.socket_fd = os.accept(lfd, null, null, os.SOCK.NONBLOCK) catch
            return;

        log.info("new client: {}", .{self.socket_fd.?});

        self.is_alive = true;
        return self.forward();
    }

    fn stop(self: *Endpoint) void {
        self.is_alive = false;
        if (self.socket_fd) |fd| {
            os.shutdown(fd, .both) catch {};
            self.socket_fd = null;
        }

        if (self.bridge_fd) |fd| {
            os.shutdown(fd, .both) catch {};
            self.bridge_fd = null;
        }

        if (self.listen_fd) |fd| {
            os.shutdown(fd, .both) catch {};
            self.listen_fd = null;
        }
    }

    fn sendRequest(self: *Endpoint) !void {
        var req: model.Request = undefined;
        var buff = mem.asBytes(&req);

        @memset(buff, 0, buff.len);
        req.setServerName(self.config.server_name);
        req.code = self.config.endpoint_type;

        var snt: usize = 0;
        while (snt < buff.len) {
            const s = try os.send(self.bridge_fd.?, buff[snt..], 0);
            if (s == 0)
                break;

            snt += s;
        }

        if (snt != buff.len)
            return error.BrokenPacket;
    }

    fn recvResponse(self: *Endpoint) !void {
        var res: model.Response = undefined;
        var buff = mem.asBytes(&res);

        @memset(buff, 0, buff.len);

        var rcvd: usize = 0;
        while (rcvd < buff.len) {
            const r = try os.recv(self.bridge_fd.?, buff[rcvd..], 0);
            if (r == 0)
                break;

            rcvd += r;
        }

        if (rcvd != buff.len)
            return error.BrokenPacket;

        log.info("response: {s}", .{res.getMessage()});
        return switch (res.code) {
            .ACCEPTED => {},
            .REJECTED => error.Rejected,
            else => error.InvalidResponseCode,
        };
    }

    fn forward(self: *Endpoint) !void {
        const src = self.socket_fd.?;
        const dst = self.bridge_fd.?;

        var pfds: [2]os.pollfd = undefined;
        pfds[0].events = os.POLL.IN;
        pfds[1].events = os.POLL.IN;
        pfds[0].fd = src;
        pfds[1].fd = dst;

        const pipe = try os.pipe();
        defer for (pipe) |p|
            os.close(p);

        const size = self.config.buffer_size;
        while (self.is_alive) {
            log.debug("...", .{});
            if ((try os.poll(&pfds, 1000)) == 0)
                continue;

            if ((pfds[0].revents & os.POLL.IN) != 0) {
                snet.spipe(src, dst, pipe, size) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => break,
                };
            }

            if ((pfds[1].revents & os.POLL.IN) != 0) {
                snet.spipe(dst, src, pipe, size) catch |err| switch (err) {
                    error.WouldBlock => continue,
                    else => break,
                };
            }
        }
    }
};

//
// Entrypoint
//
var endpoint_g: *Endpoint = undefined;
pub fn run(config: Config) !void {
    var e = Endpoint.init(std.heap.page_allocator, config);
    defer e.deinit();

    endpoint_g = &e;
    try util.setSignalHandler(intrHandler);

    return switch (config.endpoint_type) {
        .CLIENT => e.runClient(),
        .SERVER => e.runServer(),
        else => error.InvalidEndpointType,
    };
}

// private
fn intrHandler(sig: c_int) callconv(.C) void {
    util.stderr("\n", .{});
    log.err("Interrupted: {}", .{sig});

    endpoint_g.stop();
}

test "client run" {
    try run(.{
        .bridge_host = "127.0.0.1",
        .bridge_port = 80,
        .server_name = "aaaa",
        .endpoint_type = .CLIENT,
    });
}
