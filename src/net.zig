const std = @import("std");
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const log = std.log;

pub fn setupListener(host: []const u8, port: u16) !os.socket_t {
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

pub fn connectTo(allocator: mem.Allocator, host: []const u8, port: u16) !os.socket_t {
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

pub fn splice(in: os.fd_t, out: os.fd_t, size: usize, flags: u32) !usize {
    const rc = linux.syscall6(
        .splice,
        @bitCast(usize, @as(isize, in)),
        0,
        @bitCast(usize, @as(isize, out)),
        0,
        size,
        flags,
    );

    switch (os.errno(rc)) {
        .SUCCESS => return rc,
        .AGAIN => return error.WouldBlock,
        .CONNRESET => return error.ConnectionResetByPeer,
        .BADF => unreachable,
        .INVAL => unreachable,
        .NOMEM => unreachable,
        .SPIPE => unreachable,
        else => |err| return os.unexpectedErrno(err),
    }
}

pub fn spipe(in: os.fd_t, out: os.fd_t, pipe: [2]os.fd_t, size: usize) !void {
    const flags = 0x1 | 0x2; // MOVE | NONBLOCK
    var rd = try splice(in, pipe[1], size, flags);
    if (rd == 0)
        return error.EndOfFile;

    while (rd > 0) {
        const wr = try splice(pipe[0], out, rd, flags);
        if (wr == 0)
            return error.EndOfFile;

        rd -= wr;
    }
}

//
// unit test
//
test "setupListener" {
    const fd = try setupListener("127.0.0.1", 8003);
    defer os.closeSocket(fd);
}

test "connectToBridge" {
    const fd = try connectTo(std.testing.allocator, "127.0.0.1", 80);
    defer os.closeSocket(fd);
}
