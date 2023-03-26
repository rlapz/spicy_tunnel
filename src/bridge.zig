const std = @import("std");
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
    slot: usize,
    state: State,
    is_server: bool,
    sock_fd: os.socket_t,
    pipe: ?[2]os.fd_t,
    request: model.Request,
    response: model.Response,
    bytes: usize,
    ctx: *Bridge,
    peer: ?*Endpoint,

    const State = enum {
        HANDSHAKE_RECV,
        HANDSHAKE_SEND,
        FORWARD,
        FAILED,
        DONE,
    };

    fn set(self: *Endpoint, slot: usize, sock_fd: os.socket_t, ctx: *Bridge) !void {
        self.slot = slot;
        self.is_server = false;
        self.sock_fd = sock_fd;
        self.pipe = null;
        self.bytes = 0;
        self.state = .HANDSHAKE_RECV;
        self.ctx = ctx;
        self.peer = null;
    }

    // returns index of closed peer if any, otherwise null
    fn unset(self: *Endpoint) ?usize {
        os.closeSocket(self.sock_fd);

        const ret = if (self.peer) |p| brk: {
            const slot = p.slot;
            _ = p.unset();
            self.peer = null;
            break :brk slot;
        } else brk: {
            break :brk null;
        };

        if (self.is_server) {
            if (self.pipe) |pipe| for (pipe) |p|
                os.close(p);

            self.ctx.delServer(self.request.getServerName());
        }

        return ret;
    }

    fn setAsServer(self: *Endpoint) !void {
        const pipe = try os.pipe();
        errdefer for (pipe) |p|
            os.close(p);

        try self.ctx.addServer(self.request.getServerName(), self);

        self.pipe = pipe;
        self.is_server = true;
    }

    fn setPeer(self: *Endpoint, peer: *Endpoint) !void {
        if (!self.is_server)
            self.pipe = peer.pipe;

        self.peer = peer;
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
        _ = self;
        return .DONE;
    }

    fn handleHandshakeSend(self: *Endpoint) State {
        _ = self;
        return .DONE;
    }

    inline fn handleForward(self: *Endpoint) State {
        snet.spipe(
            self.peer.?.sock_fd,
            self.sock_fd,
            self.pipe.?,
            buffer_size,
        ) catch |err| switch (err) {
            error.WouldBlock => return .FORWARD,
            error.EndOfFile => return .DONE,
            else => {},
        };

        return .FAILED;
    }
};

const EndpointMap = std.AutoArrayHashMap(usize, *Endpoint);
const ServerMap = std.StringArrayHashMap(*Endpoint);
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

        var indexer = try allocator.alloc(usize, size);
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

        self.* = undefined;
    }

    fn run(self: *Bridge) !void {
        const listen = &self.config.listen;
        const sock_fd = try snet.setupListener(listen.host, listen.port);
        self.sock_fd = sock_fd;

        self.pollfds[0].fd = sock_fd;
        self.pollfds[0].events = os.POLL.IN | os.POLL.PRI;
        self.count += 1;

        self.is_alive = true;
        while (self.is_alive) {
            const fds = self.pollfds[0..];
            if (try std.os.poll(fds, 1000) == 0)
                continue;

            self.handleEvents();
        }
    }

    inline fn handleEvents(self: *Bridge) void {
        var iter: usize = 0;
        var count = self.count;

        while (iter < count) : (iter += 1) {
            if (self.pollfds[iter].revents != os.POLL.IN)
                continue;

            if (iter == 0) {
                self.addEndpoint() catch |err|
                    log.err("err: {s}", .{@errorName(err)});
                continue;
            }

            iter = switch (self.endpoint_pool[self.indexer[iter - 1]].handle()) {
                .FAILED, .DONE => self.delEndpoint(iter, &count),
                else => iter,
            };
        }
    }

    // TODO: Close all socket descriptors
    fn stop(self: *Bridge) void {
        self.is_alive = false;
        if (self.sock_fd) |fd|
            os.shutdown(fd, .both) catch {};
    }

    fn addEndpoint(self: *Bridge) !void {
        const fd = try os.accept(self.sock_fd.?, null, null, 0);
        const slot = self.slots.popOrNull() orelse
            return error.SlotFull;

        errdefer self.slots.append(slot) catch
            unreachable;

        try self.endpoint_pool[slot].set(slot, fd, self);

        const count = self.count;
        self.indexer[count - 1] = slot;

        self.pollfds[count].fd = fd;
        self.pollfds[count].events = std.os.POLL.IN;
        self.count = count + 1;

        log.debug(
            "New connection: fd: {}, count: {}, slot: {}",
            .{ fd, self.count, slot },
        );
    }

    fn delEndpoint(self: *Bridge, index: usize, count: *usize) usize {
        var _count = count.*;
        const slot_curr = self.indexer[index - 1];

        self.slots.append(slot_curr) catch
            unreachable;

        log.debug("Closed connection: fd: {}, count: {}, slot: {}", .{
            self.endpoint_pool[slot_curr].sock_fd,
            count.*,
            slot_curr,
        });

        var sub: u8 = 0;
        if (self.endpoint_pool[slot_curr].unset()) |v| {
            const _slot = self.indexer[v - 1];
            self.slots.append(_slot) catch
                unreachable;

            self.indexer[v - 1] = self.indexer[_count - 2];
            self.pollfds[v] = self.pollfds[_count - 1];
            sub += 1;

            log.debug("any closed peer", .{});
        }

        _count -= sub;
        self.indexer[index - 1] = self.indexer[_count - 1];
        self.pollfds[index] = self.pollfds[_count];

        count.* = _count;
        self.count = _count;

        return (index - sub);
    }

    fn addServer(self: *Bridge, name: []const u8, srv: *Endpoint) !void {
        self.server_map.putNoClobber(name, srv) catch
            return error.ServerExists;
    }

    fn delServer(self: *Bridge, name: []const u8) void {
        _ = self.server_map.swapRemove(name);
    }

    fn getServer(self: *Bridge, name: []const u8) !*Endpoint {
        if (self.server_map.fetchSwapRemove(name)) |kv|
            return kv.value;

        return error.NoSuchServer;
    }
};

//
// Entrypoint
//
var bridge_g: *Bridge = undefined;
pub fn run(config: Config) !void {
    var b = try Bridge.init(std.heap.page_allocator, config);
    defer b.deinit();

    bridge_g = &b;
    try util.setSignalHandler(intrHandler);

    return b.run();
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
