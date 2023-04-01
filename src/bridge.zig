const std = @import("std");
const builtin = @import("builtin");
const heap = std.heap;
const log = std.log;
const mem = std.mem;
const os = std.os;
const io = std.io;
const linux = std.linux;

const model = @import("model.zig");
const util = @import("util.zig");
const snet = @import("net.zig");

const Request = model.Request;
const Response = model.Response;

const buffer_size = 8192;

pub const Config = struct {
    listen: struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8001,
    } = .{},
    connection_max: u16 = 32,
};

const Endpoint = struct {
    state: State,

    index: usize,
    ref_count: u8,

    sock_fd: os.socket_t,
    pipe: ?[2]os.fd_t,

    request: Request,
    response: Response,
    bytes: usize,

    is_success: bool,
    server_state: ServerState,

    bridge: *Bridge,
    peer: ?*Endpoint,

    const State = enum(u8) {
        HANDSHAKE_RECV,
        HANDSHAKE_SEND,
        FORWARD,
        FAILED,
        DONE,
    };

    const ServerState = packed struct(u8) {
        active: bool = false,
        available: bool = false,
        __pad: u6 = 0,
    };

    fn init(self: *Endpoint, bridge: *Bridge) void {
        self.bridge = bridge;
    }

    fn set(self: *Endpoint, fd: os.socket_t) void {
        self.state = .HANDSHAKE_RECV;
        self.index = self.bridge.count;
        self.sock_fd = fd;
        self.server_state = ServerState{};
        self.pipe = null;
        self.bytes = 0;
        self.peer = null;
        self.ref_count = 0;
    }

    // returns index of the closed peer if any, otherwise null
    fn unset(self: *Endpoint) ?usize {
        if (self.ref_count == 0)
            return null;

        log.debug("unset", .{});
        self.ref_count -= 1;

        var ret: ?usize = null;
        if (self.peer) |peer| {
            ret = peer.index;
            _ = peer.unset();
            self.peer = null;
        }

        if (self.server_state.active) {
            if (self.pipe) |pipe| for (pipe) |p|
                os.close(p);

            const name = self.request.getServerName();
            self.bridge.delServer(name) catch |err|
                log.err("Endpoint: unset: {s}", .{@errorName(err)});

            self.server_state.active = false;
        }

        os.closeSocket(self.sock_fd);
        return ret;
    }

    fn setAsServer(self: *Endpoint) !void {
        const pipe = try os.pipe();
        errdefer for (pipe) |p|
            os.close(p);

        const name = self.request.getServerName();
        try self.bridge.addServer(name, self);

        self.pipe = pipe;
        self.server_state = .{
            .active = true,
            .available = true,
        };

        self.ref_count += 1;
    }

    fn setPeer(self: *Endpoint, peer: *Endpoint) !void {
        if (!self.server_state.active)
            self.pipe = peer.pipe;

        var peer_server_state = &peer.server_state;
        if (!peer_server_state.available)
            return error.ServerBusy;

        peer_server_state.available = false;
        peer.peer = self;

        self.peer = peer;
        self.ref_count += 1;
    }

    fn handle(self: *Endpoint) State {
        const new_state = switch (self.state) {
            .FORWARD => self.handleForward(),
            .HANDSHAKE_RECV => self.handleHandshakeRecv(),
            .HANDSHAKE_SEND => self.handleHandshakeSend(),
            .FAILED, .DONE => |res| return res,
        };

        log.debug("handle: {}", .{new_state});

        self.state = new_state;
        return new_state;
    }

    fn handleHandshakeRecv(self: *Endpoint) State {
        var buff = mem.asBytes(&self.request);
        const size = @sizeOf(Request);

        var recvd = self.bytes;
        if (recvd < size) brk: {
            const r = os.recv(self.sock_fd, buff[recvd..], 0) catch |err| {
                if (err == error.WouldBlock)
                    return .HANDSHAKE_RECV;

                return self.responseFailed("internal error");
            };

            if (r == 0)
                return .DONE;

            recvd += r;
            if (recvd >= size)
                break :brk;

            self.bytes = recvd;
            return .HANDSHAKE_RECV;
        }

        if (recvd != size)
            return self.responseFailed("request data corrupted");

        self.bytes = 0;
        self.bridge.setPollEvent(self.index, os.POLL.OUT);
        return self.setRole();
    }

    fn setRole(self: *Endpoint) State {
        switch (self.request.code) {
            .CLIENT => {
                const name = self.request.getServerName();
                util.validateServerName(name) catch |err|
                    return self.responseFailed(@errorName(err));

                const srv = self.bridge.getServerFrom(name) catch |err|
                    return self.responseFailed(@errorName(err));

                self.setPeer(srv) catch |err|
                    return self.responseFailed(@errorName(err));

                return self.responseSuccess("ok");
            },
            .SERVER => {
                self.setAsServer() catch |err| switch (err) {
                    error.ServerExists => {
                        return self.responseFailed(@errorName(err));
                    },
                    else => {
                        return self.responseFailed("internal error");
                    },
                };

                return self.responseSuccess("ok");
            },
            else => {},
        }

        return self.responseFailed("invalid request code");
    }

    fn handleHandshakeSend(self: *Endpoint) State {
        var buff = mem.asBytes(&self.response);
        const size = @sizeOf(Response);

        var sent = self.bytes;
        if (sent < size) brk: {
            const s = os.send(self.sock_fd, buff[sent..], 0) catch |err| {
                if (err == error.WouldBlock)
                    return .HANDSHAKE_SEND;

                return .FAILED;
            };

            if (s == 0)
                return .DONE;

            sent += s;
            if (sent >= size)
                break :brk;

            self.bytes = sent;
            return .HANDSHAKE_SEND;
        }

        if (sent != size)
            return .FAILED;

        self.bridge.setPollEvent(self.index, os.POLL.IN);
        if (self.is_success)
            return .FORWARD;

        return .FAILED;
    }

    inline fn handleForward(self: *Endpoint) State {
        const fd = if (self.peer) |peer|
            peer.sock_fd
        else
            return .DONE;

        snet.spipe(self.sock_fd, fd, self.pipe.?, buffer_size) catch |err| {
            switch (err) {
                error.WouldBlock => return .FORWARD,
                error.EndOfFile => return .DONE,
                else => {},
            }
        };

        snet.spipe(fd, self.sock_fd, self.pipe.?, buffer_size) catch |err| {
            switch (err) {
                error.WouldBlock => return .FORWARD,
                error.EndOfFile => return .DONE,
                else => {},
            }
        };

        return .FAILED;
    }

    fn responseFailed(self: *Endpoint, message: []const u8) State {
        self.response.code = .REJECTED;
        self.response.setMessage(message);
        self.is_success = false;
        return .HANDSHAKE_SEND;
    }

    fn responseSuccess(self: *Endpoint, message: []const u8) State {
        self.response.code = .ACCEPTED;
        self.response.setMessage(message);
        self.is_success = true;
        return .HANDSHAKE_SEND;
    }
};

const IndexMap = std.AutoHashMap(usize, usize);
const ServerMap = std.StringHashMap(*Endpoint);
const Slots = std.ArrayList(usize);

const Bridge = struct {
    allocator: mem.Allocator,
    config: Config,
    is_alive: bool,
    sock_fd: ?os.socket_t,
    server_map: ServerMap,
    index_map: []usize,
    endpoints: []Endpoint,
    pollfds: []os.pollfd,
    slots: Slots,
    count: usize,

    fn init(allocator: mem.Allocator, config: Config) !Bridge {
        const size = config.connection_max;

        var pollfds = try allocator.alloc(os.pollfd, size + 1);
        errdefer allocator.free(pollfds);

        var slots = try Slots.initCapacity(allocator, size);
        errdefer slots.deinit();

        var endpoints = try allocator.alloc(Endpoint, size);
        errdefer allocator.free(endpoints);

        var index_map = try allocator.alloc(usize, size + 1);
        errdefer allocator.free(index_map);

        var i = size;
        while (i > 0) : (i -= 1)
            try slots.append(i - 1);

        return .{
            .allocator = allocator,
            .config = config,
            .is_alive = false,
            .sock_fd = null,
            .server_map = ServerMap.init(allocator),
            .index_map = index_map,
            .endpoints = endpoints,
            .pollfds = pollfds,
            .slots = slots,
            .count = 0,
        };
    }

    fn deinit(self: *Bridge) void {
        self.server_map.deinit();
        self.allocator.free(self.index_map);
        self.allocator.free(self.endpoints);
        self.allocator.free(self.pollfds);
        self.slots.deinit();

        if (self.sock_fd) |sock_fd|
            os.closeSocket(sock_fd);

        self.* = undefined;
    }

    fn run(self: *Bridge) !void {
        for (self.endpoints) |*endpoint|
            endpoint.init(self);

        const listen = &self.config.listen;
        self.sock_fd = try snet.setupListener(listen.host, listen.port);

        self.pollfds[0].fd = self.sock_fd.?;
        self.pollfds[0].events = os.POLL.IN | os.POLL.PRI;
        self.count += 1;

        self.is_alive = true;
        while (self.is_alive) {
            if (try std.os.poll(self.pollfds[0..self.count], 1000) == 0)
                continue;

            self.handleEvents();
        }
    }

    // TODO: Close all socket descriptors
    fn stop(self: *Bridge) void {
        self.is_alive = false;
        if (self.sock_fd) |sock_fd|
            os.shutdown(sock_fd, .both) catch {};
    }

    inline fn handleEvents(self: *Bridge) void {
        var iter: usize = 0;
        var count = self.count;

        while (iter < count) : (iter += 1) {
            const rv = self.pollfds[iter].revents;

            //log.debug("iter: {}: count: {}: fd: {}", .{
            //    iter,
            //    count,
            //    self.pollfds[iter].fd,
            //});

            if (iter == 0 and (rv & os.POLL.IN) != 0) {
                self.addEndpoint() catch |err|
                    log.err("handleEvents: {s}", .{@errorName(err)});

                continue;
            }

            if (rv & (os.POLL.IN | os.POLL.OUT) != 0) {
                const index = self.index_map[iter];
                switch (self.endpoints[index].handle()) {
                    .FAILED, .DONE => {
                        iter = self.delEndpoint(iter, &count);
                    },
                    else => {},
                }
            }
        }
    }

    fn addEndpoint(self: *Bridge) !void {
        const fd = try os.accept(self.sock_fd.?, null, null, os.SOCK.NONBLOCK);
        const slot = self.slots.popOrNull() orelse
            return error.SlotFull;

        errdefer self.slots.append(slot) catch
            unreachable;

        self.endpoints[slot].set(fd);

        const count = self.count;
        self.index_map[count] = slot;
        self.pollfds[count].fd = fd;
        self.pollfds[count].events = os.POLL.IN;
        self.count = count + 1;

        log.info(
            "New connection: fd: {}, count: {}, slot: {}",
            .{ fd, self.count, slot },
        );
    }

    fn delEndpoint(self: *Bridge, index: usize, count: *usize) usize {
        const slot = self.index_map[index];

        var _count = count.*;
        log.debug("Closed connection: fd: {}, count: {}, slot: {}", .{
            self.endpoints[slot].sock_fd,
            count.*,
            slot,
        });

        var sub: u8 = 1;
        if (self.endpoints[slot].unset()) |v| {
            const _slot = self.index_map[v];
            self.slots.append(_slot) catch
                unreachable;

            _count -= 1;
            self.index_map[v] = self.index_map[_count];
            self.pollfds[v] = self.pollfds[_count];
            sub += 1;

            log.debug("any closed peer: {}: fd: {}", .{ v, self.pollfds[v].fd });
        }

        log.debug("closed: {}", .{index});

        _count -= 1;
        self.index_map[index] = self.index_map[_count];
        self.pollfds[index] = self.pollfds[_count];
        self.slots.append(slot) catch
            unreachable;

        count.* = _count;
        self.count = _count;

        if (index < sub)
            return index;

        return (index - sub);
    }

    fn addServer(self: *Bridge, name: []const u8, server: *Endpoint) !void {
        _ = name;
        if (self.server_map.contains("test"))
            return error.ServerExists;

        try self.server_map.put("test", server);
    }

    fn delServer(self: *Bridge, name: []const u8) !void {
        _ = name;
        if (self.server_map.contains("test")) {
            if (!self.server_map.remove("test"))
                return error.FailedToRemoveServer;
        } else {
            return error.NoSuchServer;
        }
    }

    fn getServerFrom(self: *Bridge, name: []const u8) !*Endpoint {
        if (!self.server_map.contains(name))
            return error.NoSuchServer;

        return self.server_map.get(name).?;
    }

    fn setPollEvent(self: *Bridge, index: usize, mode: i16) void {
        self.pollfds[index].events = mode;
    }
};

//
// Entrypoint
//
var bridge_g: *Bridge = undefined;

pub fn run(config: Config) !void {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        log.info("Release {}", .{builtin.mode});
        var gpa = heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();

        var b = try Bridge.init(gpa.allocator(), config);
        defer b.deinit();

        bridge_g = &b;
        try util.setSignalHandler(intrHandler);

        return b.run();
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
