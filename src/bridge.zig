const std = @import("std");
const builtin = @import("builtin");
const heap = std.heap;
const log = std.log;
const mem = std.mem;
const os = std.os;
const io = std.io;
const linux = os.linux;

const dprint = std.debug.print;

const model = @import("model.zig");
const util = @import("util.zig");
const snet = @import("net.zig");

const buffer_size = 4096;

pub const Config = struct {
    listen: struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8001,
    } = .{},
    connection_max: u16 = 32,
};

const Endpoint = struct {
    state: State,

    slot: usize,
    index: usize,

    is_server: bool,
    is_server_avail: bool,
    is_failed: bool,

    sock_fd: os.socket_t,
    pipe: ?[2]os.fd_t,

    request: model.Request,
    response: model.Response,
    bytes: usize,

    ctx: *Bridge,
    peer: ?*Endpoint,

    const State = enum(u32) {
        HANDSHAKE_RECV,
        HANDSHAKE_SEND,
        FORWARD,
        FAILED,
        DONE,
    };

    fn init(self: *Endpoint, ctx: *Bridge) void {
        self.ctx = ctx;
    }

    fn set(self: *Endpoint, slot: usize, sock_fd: os.socket_t) !void {
        self.state = .HANDSHAKE_RECV;
        self.slot = slot;
        self.index = self.ctx.count;
        self.is_server = false;
        self.is_server_avail = false;
        self.sock_fd = sock_fd;
        self.pipe = null;
        self.bytes = 0;
        self.peer = null;
    }

    // returns slot of closed peer if any, otherwise null
    fn unset(self: *Endpoint) ?usize {
        os.closeSocket(self.sock_fd);

        var ret: ?usize = null;
        if (self.peer) |p| {
            ret = p.slot;
            _ = p.unset();
            self.peer = null;
        }

        if (self.is_server) {
            if (self.pipe) |pipe| for (pipe) |p|
                os.close(p);

            const name = self.request.getServerName();
            self.ctx.delServer(name) catch |err|
                log.err("endpoint: unset: {s}", .{@errorName(err)});
        }

        return ret;
    }

    fn setAsServer(self: *Endpoint) !void {
        const pipe = try os.pipe();
        errdefer for (pipe) |p|
            os.close(p);

        const name = self.request.getServerName();
        log.debug("setAsServer: name: {s}", .{name});

        try self.ctx.addServer(name, self);

        self.pipe = pipe;
        self.is_server = true;
        self.is_server_avail = true;
    }

    fn setPeer(self: *Endpoint, peer: *Endpoint) !void {
        if (!self.is_server)
            self.pipe = peer.pipe;

        if (!peer.is_server_avail)
            return error.ServerBusy;

        peer.is_server_avail = false;
        peer.peer = self;

        self.peer = peer;
    }

    fn setFailed(self: *Endpoint, msg: []const u8) State {
        self.response.code = .REJECTED;
        self.response.setMessage(msg);
        self.is_failed = true;
        return .HANDSHAKE_SEND;
    }

    fn setSuccess(self: *Endpoint) State {
        self.response.code = .ACCEPTED;
        self.response.setMessage("ok");
        self.is_failed = false;
        return .HANDSHAKE_SEND;
    }

    fn handle(self: *Endpoint) State {
        const new_state = switch (self.state) {
            .FORWARD => self.handleForward(),
            .HANDSHAKE_RECV => self.handleHandshakeRecv(),
            .HANDSHAKE_SEND => self.handleHandshakeSend(),
            .FAILED, .DONE => |r| return r,
        };

        self.state = new_state;
        return new_state;
    }

    fn handleHandshakeRecv(self: *Endpoint) State {
        const req_size = @sizeOf(model.Request);

        var recvd = self.bytes;
        if (recvd < req_size) brk: {
            var buff = mem.asBytes(&self.request);
            const r = os.recv(self.sock_fd, buff[recvd..], 0) catch |err| {
                if (err == error.WouldBlock)
                    return .HANDSHAKE_RECV;

                return self.setFailed("internal error");
            };

            if (r == 0)
                return .DONE;

            recvd += r;
            if (recvd >= req_size)
                break :brk;

            self.bytes = recvd;
            return .HANDSHAKE_RECV;
        }

        if (recvd != req_size)
            return self.setFailed("corrupted request data");

        self.bytes = 0;
        self.ctx.setPollEvent(self.index, os.POLL.OUT);
        return self.setRole();
    }

    fn setRole(self: *Endpoint) State {
        switch (self.request.code) {
            .CLIENT => {
                const name = self.request.getServerName();
                util.validateServerName(name) catch |err|
                    return self.setFailed(@errorName(err));

                const srv = self.ctx.getServer(name) catch |err|
                    return self.setFailed(@errorName(err));

                self.setPeer(srv) catch |err|
                    return self.setFailed(@errorName(err));

                return self.setSuccess();
            },
            .SERVER => {
                self.setAsServer() catch |err| switch (err) {
                    error.ServerExists => return self.setFailed(@errorName(err)),
                    else => return self.setFailed("internal error"),
                };

                return self.setSuccess();
            },
            else => return self.setFailed("invalid request code"),
        }

        return self.setFailed("internal error");
    }

    fn handleHandshakeSend(self: *Endpoint) State {
        const res_size = @sizeOf(model.Response);

        var sent = self.bytes;
        if (sent < res_size) brk: {
            var buff = mem.asBytes(&self.response);
            const s = os.send(self.sock_fd, buff[sent..], 0) catch |err| {
                if (err == error.WouldBlock)
                    return .HANDSHAKE_SEND;

                return .FAILED;
            };

            if (s == 0)
                return .DONE;

            sent += s;
            if (sent >= res_size)
                break :brk;

            self.bytes = sent;
            return .HANDSHAKE_SEND;
        }

        if (sent != res_size)
            return .FAILED;

        self.bytes = 0;
        self.ctx.setPollEvent(self.index, os.POLL.IN);

        if (self.is_failed)
            return .FAILED;

        return .FORWARD;
    }

    inline fn handleForward(self: *Endpoint) State {
        const fd = if (self.peer) |p|
            p.sock_fd
        else
            return .DONE;

        snet.spipe(self.sock_fd, fd, self.pipe.?, buffer_size) catch |err| {
            switch (err) {
                error.WouldBlock => return .FORWARD,
                error.EndOfFile => return .DONE,
                else => {},
            }
        };

        return .FAILED;
    }
};

const EndpointMap = std.AutoArrayHashMap(usize, *Endpoint);
const ServerMap = std.StringHashMap(*Endpoint);
const SlotArray = std.ArrayList(usize);

const Bridge = struct {
    allocator: mem.Allocator,
    config: Config,
    is_alive: bool,
    sock_fd: ?os.socket_t,
    pollfds: []os.pollfd,
    server_map: ServerMap,
    endpoint_pool: []Endpoint,
    indexer: []usize,
    count: usize,
    slots: SlotArray,

    fn init(allocator: mem.Allocator, config: Config) !Bridge {
        const size = config.connection_max;
        var pollfds = try allocator.alloc(os.pollfd, size + 1);
        errdefer allocator.free(pollfds);

        var indexer = try allocator.alloc(usize, size + 1);
        errdefer allocator.free(indexer);

        var slots = try SlotArray.initCapacity(allocator, size);
        errdefer slots.deinit();

        var i = size;
        while (i > 0) : (i -= 1)
            try slots.append(i - 1);

        return .{
            .allocator = allocator,
            .config = config,
            .is_alive = false,
            .sock_fd = null,
            .pollfds = pollfds,
            .server_map = ServerMap.init(allocator),
            .endpoint_pool = try allocator.alloc(Endpoint, size),
            .slots = slots,
            .indexer = indexer,
            .count = 0,
        };
    }

    fn deinit(self: *Bridge) void {
        self.allocator.free(self.pollfds);
        self.allocator.free(self.endpoint_pool);
        self.allocator.free(self.indexer);
        self.server_map.deinit();
        self.slots.deinit();

        if (self.sock_fd) |fd|
            os.closeSocket(fd);

        self.* = undefined;
    }

    fn run(self: *Bridge) !void {
        for (self.endpoint_pool) |*e|
            e.init(self);

        const listen = &self.config.listen;
        const sock_fd = try snet.setupListener(listen.host, listen.port);
        self.sock_fd = sock_fd;

        self.pollfds[0].fd = sock_fd;
        self.pollfds[0].events = os.POLL.IN | os.POLL.PRI;
        self.count += 1;

        self.is_alive = true;
        while (self.is_alive) {
            const fds = self.pollfds[0..self.count];
            if (try std.os.poll(fds, 1000) == 0)
                continue;

            self.handleEvents();
        }
    }

    inline fn handleEvents(self: *Bridge) void {
        var iter: usize = 0;
        var count = self.count;

        while (iter < count) : (iter += 1) {
            const rv = self.pollfds[iter].revents;

            if (iter == 0 and (rv & os.POLL.IN) != 0) {
                self.addEndpoint() catch |err|
                    log.err("err: {s}", .{@errorName(err)});

                continue;
            }

            if (rv & (os.POLL.IN | os.POLL.OUT) != 0) {
                switch (self.endpoint_pool[self.indexer[iter]].handle()) {
                    .FAILED, .DONE => {
                        iter = self.delEndpoint(iter, &count);
                    },
                    else => {},
                }
            }
        }
    }

    // TODO: Close all socket descriptors
    fn stop(self: *Bridge) void {
        self.is_alive = false;
        if (self.sock_fd) |fd|
            os.shutdown(fd, .both) catch {};
    }

    fn addEndpoint(self: *Bridge) !void {
        const fd = try os.accept(self.sock_fd.?, null, null, os.SOCK.NONBLOCK);
        const slot = self.slots.popOrNull() orelse
            return error.SlotFull;

        errdefer self.slots.append(slot) catch
            unreachable;

        try self.endpoint_pool[slot].set(slot, fd);

        const count = self.count;
        self.indexer[count] = slot;
        self.pollfds[count].fd = fd;
        self.pollfds[count].events = std.os.POLL.IN;
        self.count = count + 1;

        log.info(
            "New connection: fd: {}, count: {}, slot: {}",
            .{ fd, self.count, slot },
        );
    }

    fn delEndpoint(self: *Bridge, index: usize, count: *usize) usize {
        var _count = count.*;
        const slot_curr = self.indexer[index];

        self.slots.append(slot_curr) catch
            unreachable;

        log.debug("Closed connection: fd: {}, count: {}, slot: {}", .{
            self.endpoint_pool[slot_curr].sock_fd,
            count.*,
            slot_curr,
        });

        var sub: u8 = 1;
        if (self.endpoint_pool[slot_curr].unset()) |v| {
            const _slot = self.indexer[v];
            self.slots.append(_slot) catch
                unreachable;

            _count -= 1;
            self.indexer[v] = self.indexer[_count];
            self.pollfds[v] = self.pollfds[_count];
            sub += 1;

            log.debug("any closed peer", .{});
        }

        _count -= 1;
        self.indexer[index] = self.indexer[_count];
        self.pollfds[index] = self.pollfds[_count];

        count.* = _count;
        self.count = _count;

        return (index - sub);
    }

    fn addServer(self: *Bridge, name: []const u8, srv: *Endpoint) !void {
        if (self.server_map.contains(name))
            return error.ServerExists;

        try self.server_map.put(name, srv);
    }

    fn delServer(self: *Bridge, name: []const u8) !void {
        if (!self.server_map.remove(name))
            return error.NoSuchServer;

        //if (self.server_map.contains(name)) {
        //    if (!self.server_map.remove(name))
        //        return error.FailedToRemoveServer;
        //} else {
        //    return error.NoSuchServer;
        //}
    }

    fn getServer(self: *Bridge, name: []const u8) !*Endpoint {
        return self.server_map.get(name) orelse
            error.NoSuchServer;

        //if (!self.server_map.contains(name))
        //    return error.NoSuchServer;

        //return self.server_map.get(name).?;
    }

    fn setPollEvent(self: *Bridge, poll_index: usize, mode: i16) void {
        self.pollfds[poll_index].events = mode;
    }
};

//
// Entrypoint
//
var bridge_g: *Bridge = undefined;

fn runSafe(config: Config) !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var b = try Bridge.init(gpa.allocator(), config);
    defer b.deinit();

    bridge_g = &b;
    try util.setSignalHandler(intrHandler);

    return b.run();
}

pub fn run(config: Config) !void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        log.info("Release {}", .{builtin.mode});
        return runSafe(config);
    } else {
        var b = try Bridge.init(std.heap.page_allocator, config);
        defer b.deinit();

        bridge_g = &b;
        try util.setSignalHandler(intrHandler);

        return b.run();
    }
}

// private
fn intrHandler(sig: c_int) callconv(.C) void {
    util.stderr("\n", .{});
    log.err("Interrupted: {}", .{sig});

    bridge_g.stop();
}

test "bridge run" {
    var bridge = try Bridge.init(std.testing.allocator, .{});
    defer bridge.deinit();

    try bridge.run();
}
