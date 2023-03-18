const std = @import("std");
const mem = std.mem;
const os = std.os;
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
