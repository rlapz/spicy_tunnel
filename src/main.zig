const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const os = std.os;

const bridge = @import("bridge.zig");
const endpoint = @import("endpoint.zig");
const util = @import("util.zig");
const model = @import("model.zig");

noinline fn showHelp(app: [*:0]const u8) void {
    @setCold(true);
    util.stdout(
        \\Spicy Tunnel
        \\
        \\Usages:
        \\ 1. Bridge
        \\    {s} bridge [listen host] [listen port]
        \\
        \\    Example:
        \\      {s} bridge 127.0.0.1 8003
        \\
        \\ 2. Server
        \\    {s} server [listen host] [listen port] [bridge host] \
        \\        [bridge port] [name]
        \\
        \\    Example:
        \\      {s} server 127.0.0.1 8002 192.168.0.1 8999 my_server
        \\
        \\ 3. Client
        \\    {s} client [listen host] [listen port] [bridge host] \
        \\        [bridge port] [server name]
        \\
        \\    Example:
        \\      {s} client 127.0.0.1 8001 192.168.0.1 8999 my_server
        \\
        \\
    ,
        .{ app, app, app, app, app, app },
    );
}

fn runBridge(argv: [][*:0]u8) !void {
    return bridge.run(.{
        .listen = .{
            .host = mem.span(argv[2]),
            .port = try fmt.parseUnsigned(u16, mem.span(argv[3]), 10),
        },
    });
}

fn runEndpoint(argv: [][*:0]u8, e_type: model.Request.Code) !void {
    if (argv.len != 7)
        return error.InvalidArgument;

    return endpoint.run(.{
        .listen_host = mem.span(argv[2]),
        .listen_port = try fmt.parseUnsigned(u16, mem.span(argv[3]), 10),
        .bridge_host = mem.span(argv[4]),
        .bridge_port = try fmt.parseUnsigned(u16, mem.span(argv[5]), 10),
        .server_name = mem.span(argv[6]),
        .endpoint_type = e_type,
    });
}

pub fn main() !void {
    var need_help = true;
    const argv = os.argv;
    errdefer if (need_help)
        showHelp(argv[0]);

    if (argv.len == 1)
        return error.InvalidArgument;

    const stype = mem.span(argv[1]);
    if (mem.eql(u8, stype, "bridge"))
        return runBridge(argv)
    else if (mem.eql(u8, stype, "server"))
        return runEndpoint(argv, .SERVER)
    else if (mem.eql(u8, stype, "client"))
        return runEndpoint(argv, .CLIENT);

    return error.InvalidArgument;
}
