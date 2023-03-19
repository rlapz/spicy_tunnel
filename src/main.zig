const std = @import("std");
const mem = std.mem;
const os = std.os;

const bridge = @import("bridge.zig");
const endpoint = @import("endpoint.zig");
const util = @import("util.zig");

fn showHelp(app: [*:0]const u8) void {
    util.stdout(
        \\Spicy Tunnel
        \\
        \\Usages:
        \\ 1. Bridge
        \\    {s} [listen host] [listen port]
        \\
        \\    Example:
        \\      {s} 127.0.0.1 8003
        \\
        \\ 2. Server
        \\    {s} [listen host] [listen port] [bridge host] \
        \\        [bridge port] [name]
        \\
        \\    Example:
        \\      {s} 127.0.0.1 8002 192.168.0.1 8999 my_server
        \\
        \\ 3. Client
        \\    {s} [listen host] [listen port] [bridge host] \
        \\        [bridge port] [server name]
        \\
        \\    Example:
        \\      {s} 127.0.0.1 8001 192.168.0.1 8999 my_server
        \\
    ,
        .{ app, app, app, app, app, app },
    );
}

pub fn main() !void {
    var need_help = true;
    const argv = os.argv;
    errdefer if (need_help)
        showHelp(argv[0]);

    if (argv.len == 1)
        return error.InvalidArgument;

    const stype = mem.span(argv[1]);
    if (mem.eql(u8, stype, "bridge")) {
        if (argv.len != 4)
            return error.InvalidArgument;
    } else if (mem.eql(u8, stype, "server")) {
        if (argv.len != 7)
            return error.InvalidArgument;
    } else if (mem.eql(u8, stype, "client")) {
        if (argv.len != 7)
            return error.InvalidArgument;
    } else {
        return error.InvalidArgument;
    }
}
