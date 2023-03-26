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

pub const Config = struct {
    listen: struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8001,
    } = .{},
    connection_max: u16 = 32,
    buffer_size: usize = 4096,
};

const Endpoint = struct {
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

    fn set(self: *Endpoint, sock_fd: os.socket_t, ctx: *Bridge) !void {
        self.is_server = false;
        self.sock_fd = sock_fd;
        self.pipe = null;
        self.bytes = 0;
        self.state = .HANDSHAKE_RECV;
        self.ctx = ctx;
        self.peer = null;
    }

    fn unset(self: *Endpoint) void {
        os.closeSocket(self.sock_fd);
        if (self.peer) |p| {
            p.unset();
            self.peer = null;
        }

        if (self.is_server) {
            if (self.pipe) |pipe| for (pipe) |p|
                os.close(p);

            self.ctx.delServer(self.request.getServerName());
        }
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
        return .FORWARD;
    }

    fn handleHandshakeSend(self: *Endpoint) State {
        _ = self;
        return .FORWARD;
    }

    inline fn handleForward(self: *Endpoint) State {
        return snet.spipe(
            self.peer.?.sock_fd,
            self.sock_fd,
            self.pipe.?,
            self.config.buffer_size,
        ) catch |err| switch (err) {
            error.WouldBlock => .FORWARD,
            error.EndOfFile => .DONE,
            else => .FAILED,
        };
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
    endpoint_map: EndpointMap,
    endpoint_pool: []Endpoint,
    slots: SlotArray,

    fn init(allocator: mem.Allocator, config: Config) !Bridge {
        var size = config.connection_max;
        var pollfds = try allocator.alloc(os.pollfd, size + 1);
        errdefer allocator.free(pollfds);

        var slots = try SlotArray.initCapacity(allocator, size);
        errdefer slots.deinit();

        while (size > 0) : (size -= 1)
            try slots.append(size - 1);

        return .{
            .allocator = allocator,
            .config = config,
            .is_alive = false,
            .sock_fd = null,
            .pollfds = pollfds,
            .server_map = ServerMap.init(allocator),
            .endpoint_map = EndpointMap.init(allocator),
            .endpoint_pool = try allocator.alloc(Endpoint, size),
            .slots = slots,
        };
    }

    fn deinit(self: *Bridge) void {
        self.allocator.free(self.pollfds);
        self.allocator.free(self.endpoint_pool);
        self.server_map.deinit();
        self.endpoint_map.deinit();
        self.slots.deinit();

        self.* = undefined;
    }

    fn run(self: *Bridge) !void {
        const listen = &self.config.listen;
        self.sock_fd = try snet.setupListener(listen.host, listen.port);
        self.is_alive = true;

        // TODO: main loop
        while (self.is_alive) {}
    }

    // TODO: Close all socket descriptors
    fn stop(self: *Bridge) void {
        self.is_alive = false;
        if (self.sock_fd) |fd|
            os.shutdown(fd, .both) catch {};
    }

    // TODO: pollfds map
    fn addEndpoint(self: *Bridge, fd: os.socket_t) !void {
        const slot = self.slots.popOrNull() orelse
            return error.SlotFull;

        errdefer self.slots.append(slot) catch
            unreachable;

        try self.endpoint_pool[slot].set(fd, self);
    }

    // TODO: pollfds map
    fn delEndpoint(self: *Bridge, idx: usize) void {
        self.endpoint_pool[idx].unset();

        self.slots.append(idx) catch
            unreachable;
    }

    fn addServer(self: *Bridge, name: []const u8, srv: *Endpoint) !void {
        if (self.server_map.contains(name))
            return error.ServerAlreadyExists;

        try self.server_map.put(name, srv);
    }

    fn delServer(self: *Bridge, name: []const u8) void {
        _ = self.server_map.swapRemove(name);
    }

    fn chkServer(self: *Bridge, name: []const u8) bool {
        return self.server_map.contains(name);
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
