const std = @import("std");
const mem = std.mem;
const os = std.os;
const io = std.io;
const linux = os.linux;

const model = @import("model.zig");
const util = @import("util.zig");
const net = @import("net.zig");

pub const Config = struct {
    listen_host: []const u8 = "127.0.0.1",
    listen_port: u16 = 8001,
    server_min: u32 = 16,
    server_max: u32 = 16,
    queue_depth: u13 = 32,
};

const Connection = struct {
    state: State,
    bridge_fd: os.socket_t,
    conn_fd: os.socket_t,
    request: model.Request,
    response: model.Response,
    uring: *linux.IO_Uring,

    const State = enum {
        REQUEST,
        RESPONSE,
        ACCEPTED_AS_SERVER,
        ACCEPTED_AS_CLIENT,
        REJECTED,
        ERROR,
    };
};

const Server = struct {
    is_available: bool,
    has_client: bool,
    state: State,
    listen_fd: os.socket_t,
    client_fd: os.socket_t,
    uring: *linux.IO_Uring,

    const State = enum {
        ERROR,
    };
};

const ConnectionPool = std.heap.MemoryPool(Connection);
const ServerPool = std.heap.MemoryPool(Server);
const ServerMap = std.StringArrayHashMap(*Server);

const Bridge = struct {
    allocator: mem.Allocator,
    config: Config,
    is_alive: bool = false,
    listen_fd: ?os.socket_t = null,
    connection_pool: ConnectionPool,
    server_pool: ServerPool,
    server_map: ServerMap,
    uring: linux.IO_Uring = undefined,

    fn init(allocator: mem.Allocator, config: Config) !Bridge {
        return .{
            .allocator = allocator,
            .config = config,
            .connection_pool = ConnectionPool.init(allocator),
            .server_pool = ServerPool.init(allocator),
            .server_map = ServerMap.init(allocator),
            .uring = try linux.IO_Uring.init(config.queue_depth, 0),
        };
    }

    fn deinit(self: *Bridge) void {
        if (self.listen_fd) |fd|
            os.closeSocket(fd);

        self.connection_pool.deinit();
        self.server_pool.deinit();
        self.server_map.deinit();
        self.uring.deinit();
    }

    fn run(self: *Bridge) !void {
        const cfg = &self.config;
        self.listen_fd = try net.setupListener(cfg.listen_host, cfg.listen_port);

        self.is_alive = true;
        return self.mainLoop();
    }

    fn stop(self: *Bridge) void {
        self.is_alive = false;
        if (self.listen_fd) |fd|
            os.shutdown(fd, .both) catch {};
    }

    fn mainLoop(self: *Bridge) !void {
        var is_alive = &self.is_alive;
        while (is_alive.*) {
            return;
        }
    }

    fn addServer(self: *Bridge, name: []const u8, srv: *Server) void {
        _ = self;
        _ = name;
        _ = srv;
    }

    fn addClient(self: *Bridge, srv_name: []const u8, cfd: os.socket_t) void {
        _ = self;
        _ = srv_name;
        _ = cfd;
    }
};

//
// Entrypoint
//
var bridge_g: *Bridge = undefined;
pub fn run(config: Config) !void {
    _ = config;
}

// private
fn intrHandler(sig: c_int) callconv(.C) void {
    _ = sig;
}

test "bridge run" {
    var b = try Bridge.init(std.testing.allocator, .{});
    try b.run();
}
