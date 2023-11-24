const std = @import("std");
const testing = std.testing;

pub fn VarInt(comptime I: type) type {
    const info = @typeInfo(I).Int;
    return struct {
        pub const U =
            @Type(.{ .Int = .{ .signedness = .unsigned, .bits = info.bits } });
        pub const MaxBytes = (info.bits + 6) / 7;
        pub const Byte = if (info.bits < 8) I else u8;

        pub const E = error{ EndOfStream, VarIntTooBig };
        pub const UT = I;

        pub fn read(reader: anytype, out: *I, _: std.mem.Allocator) !void {
            var n: U = 0;
            for (0..MaxBytes) |i| {
                const b = try reader.readByte();
                if ((b & 0b1000_0000) != 0 and i == MaxBytes - 1)
                    return error.VarIntTooBig;
                n |= @as(U, @as(u7, @truncate(b))) <<
                    (7 * @as(std.math.Log2Int(U), @intCast(i)));
                if ((b & 0b1000_0000) == 0) break;
            }
            out.* = @bitCast(n);
        }
        pub fn deinit(self: *I, _: std.mem.Allocator) void {
            self.* = undefined;
        }
        pub fn write(writer: anytype, in: I) !void {
            var n: U = @bitCast(in);
            while (true) {
                const b: u8 = @as(u7, @truncate(n));
                if (info.bits < 8)
                    n = 0
                else
                    n >>= 7;
                if (n == 0) {
                    try writer.writeByte(b);
                    break;
                } else {
                    try writer.writeByte(b | 0b1000_0000);
                }
            }
        }

        pub fn size(in: I) usize {
            return if (in == 0)
                1
            else
                ((info.bits - @clz(@as(U, @bitCast(in))) + 6) / 7);
        }
    };
}

/// State machine implementation to avoid needing to block on a reader
pub fn VarIntSM(comptime I: type) type {
    const info = @typeInfo(I).Int;
    return struct {
        pub const U =
            @Type(.{ .Int = .{ .signedness = .unsigned, .bits = info.bits } });
        pub const MaxBytes = (info.bits + 6) / 7;
        pub const Shift = std.math.Log2Int(U);

        pub const E = error{VarIntTooBig};

        value: U = 0,
        i: Shift = 0,

        const Self = @This();
        pub fn feed(self: *Self, b: u8) E!?I {
            if ((b & 0b1000_0000) != 0 and self.i == MaxBytes - 1)
                return error.VarIntTooBig;
            self.value |= @as(U, @as(u7, @truncate(b))) << (7 * self.i);
            if ((b & 0b1000_0000) == 0)
                return @bitCast(self.value);
            self.i += 1;
            return null;
        }
    };
}

pub const VarIntTestCases = .{
    .{ .T = i32, .r = 0, .v = .{0x00} },
    .{ .T = i32, .r = 1, .v = .{0x01} },
    .{ .T = i32, .r = 2, .v = .{0x02} },
    .{ .T = i32, .r = 127, .v = .{0x7f} },
    .{ .T = i32, .r = 128, .v = .{ 0x80, 0x01 } },
    .{ .T = i32, .r = 255, .v = .{ 0xff, 0x01 } },
    .{ .T = i32, .r = 25565, .v = .{ 0xdd, 0xc7, 0x01 } },
    .{ .T = i32, .r = 2097151, .v = .{ 0xff, 0xff, 0x7f } },
    .{ .T = i32, .r = 2147483647, .v = .{ 0xff, 0xff, 0xff, 0xff, 0x07 } },
    .{ .T = i32, .r = -1, .v = .{ 0xff, 0xff, 0xff, 0xff, 0x0f } },
    .{ .T = i32, .r = -2147483648, .v = .{ 0x80, 0x80, 0x80, 0x80, 0x08 } },
    .{ .T = i64, .r = 2147483647, .v = .{ 0xff, 0xff, 0xff, 0xff, 0x07 } },
    .{ .T = i64, .r = -1, .v = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 } },
    .{ .T = i64, .r = -2147483648, .v = .{ 0x80, 0x80, 0x80, 0x80, 0xf8, 0xff, 0xff, 0xff, 0xff, 0x01 } },
    .{ .T = i64, .r = 9223372036854775807, .v = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f } },
    .{ .T = i64, .r = -9223372036854775808, .v = .{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 } },
};

test "VarInt read" {
    inline for (VarIntTestCases) |pair| {
        const buf: [pair.v.len]u8 = pair.v;
        var reader = std.io.fixedBufferStream(&buf);
        var out: pair.T = undefined;
        try VarInt(pair.T).read(reader.reader(), &out, undefined);
        try testing.expectEqual(@as(pair.T, pair.r), out);
    }
}

test "VarInt write" {
    inline for (VarIntTestCases) |pair| {
        var wrote = std.ArrayList(u8).init(testing.allocator);
        defer wrote.deinit();
        try VarInt(pair.T).write(wrote.writer(), pair.r);
        const buf: [pair.v.len]u8 = pair.v;
        try testing.expect(std.mem.eql(u8, &buf, wrote.items));
    }
}

test "VarInt size" {
    inline for (VarIntTestCases) |pair| {
        try testing.expectEqual(
            @as(usize, pair.v.len),
            VarInt(pair.T).size(pair.r),
        );
    }
}

test "VarIntSM read" {
    inline for (VarIntTestCases) |pair| {
        const buf: [pair.v.len]u8 = pair.v;
        var sm = VarIntSM(pair.T){};
        var out: ?pair.T = null;
        for (&buf) |c| {
            if (try sm.feed(c)) |out_| {
                out = out_;
                break;
            }
        }
        try testing.expectEqual(@as(?pair.T, pair.r), out);
    }
}
