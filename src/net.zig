const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;

fn setupListener(host: []const u8, port: u16) !os.socket_t {
    const saddr = try net.Address.parseIp(host, port);
    const sfd = try os.socket(saddr.any.family, os.SOCK.STREAM, os.IPPROTO.TCP);

    try os.setsockopt(
        sfd,
        os.SOL.SOCKET,
        os.SO.REUSEADDR,
        &mem.toBytes(@as(c_int, 1)),
    );

    try os.bind(sfd, &saddr.any, saddr.getOsSockLen());
    try os.listen(sfd, 10);

    return sfd;
}

fn connectToBridge(allocator: mem.Allocator, host: []const u8, port: u16) !os.socket_t {
    var addr_list = try net.getAddressList(allocator, host, port);
    defer addr_list.deinit();

    if (addr_list.addrs.len == 0)
        return error.UnknownHostName;

    for (addr_list.addrs) |a| {
        const sfd = os.socket(a.any.family, os.SOCK.STREAM, os.IPPROTO.TCP) catch
            continue;

        os.connect(sfd, &a.any, a.getOsSockLen()) catch
            continue;

        // success
        return sfd;
    }

    return error.ConnectionRefused;
}

//
// unit test
//
test "setupListener" {
    const fd = try setupListener("127.0.0.1", 8003);
    defer os.closeSocket(fd);
}

test "connectToBridge" {
    const fd = try connectToBridge(std.testing.allocator, "127.0.0.1", 80);
    defer os.closeSocket(fd);
}
