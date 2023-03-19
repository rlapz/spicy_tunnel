const std = @import("std");
const mem = std.mem;
const os = std.os;
const assert = std.debug.assert;
const SIG = os.SIG;

pub const handlerFn = fn (c_int) callconv(.C) void;

pub fn setSignalHandler(handler: handlerFn) !void {
    var act = mem.zeroInit(os.Sigaction, .{
        .handler = .{ .handler = SIG.IGN },
    });

    try os.sigaction(SIG.PIPE, &act, null);

    act.handler = .{ .handler = handler };
    try os.sigaction(SIG.TERM, &act, null);
    try os.sigaction(SIG.INT, &act, null);
    try os.sigaction(SIG.HUP, &act, null);
}

pub fn toSlice(src: [*]const u8, size: usize) []const u8 {
    var i: usize = 0;
    while (i < size) {
        if (src[i] == '\x00')
            break;

        i += 1;
    }

    return src[0..i];
}

pub inline fn stdout(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(fmt, args) catch
        return;
}

pub inline fn stderr(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print(fmt, args) catch
        return;
}

pub inline fn validateServerName(str: []const u8) bool {
    for (str) |v| {
        if (!std.ascii.isASCII(v) or !std.ascii.isAlphanumeric(v))
            return false;
    }

    return true;
}

//
// Unit test
//
test "util: validateServerName" {
    const str1 = "aaaaaabbbccc?xa00";
    assert(validateServerName(str1) == false);

    const str2 = "aaabbcc0123809809jkjkjk";
    assert(validateServerName(str2));
}
