const std = @import("std");
const mem = std.mem;
const os = std.os;
const assert = std.debug.assert;
const SIG = os.SIG;

const model = @import("model.zig");

pub const handlerFn = fn (c_int) callconv(.C) void;

pub fn setSignalHandler(handler: *const handlerFn) !void {
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

pub fn validateServerName(str: []const u8) !void {
    if (str.len == 0)
        return error.ServerNameEmpty;

    if (str.len >= model.Request.server_name_size)
        return error.ServerNameTooLong;

    for (str) |v| {
        if (!std.ascii.isASCII(v) or !std.ascii.isAlphanumeric(v))
            return error.ServerNameInvalid;
    }
}

//
// Unit test
//
test "util: validateServerName" {
    const str1 = "aaaaaabbbccc?xa00";
    validateServerName(str1) catch {};

    const str2 = "aaabbcc0123809809jkjkjk";
    try validateServerName(str2);
}
