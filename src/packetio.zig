const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

const serde = @import("serde.zig");
const VarInt = @import("varint.zig").VarInt;
const VarI32 = VarInt(i32);

/// extra handling to detect legacy handshake
pub fn readHandshakePacket(comptime ST: type, reader: anytype, ctx: anytype) !ST.UT {
    var len: i32 = undefined;
    try VarI32.read(reader, &len, ctx);
    if (len == 0xFE) return .legacy;
    var lr = std.io.limitedReader(
        reader,
        math.cast(usize, len) orelse return error.InvalidLength,
    );
    var packet: ST.UT = undefined;
    ST.read(lr.reader(), &packet, ctx) catch |e| {
        if (e != error.EndOfStream) {
            lr.reader().skipBytes(lr.bytes_left, .{}) catch {};
        }
        return e;
    };
    return packet;
}
pub fn readPacket(comptime ST: type, reader: anytype, ctx: anytype) !ST.UT {
    var len: i32 = undefined;
    try VarI32.read(reader, &len, ctx);
    var lr = std.io.limitedReader(
        reader,
        math.cast(usize, len) orelse return error.InvalidLength,
    );
    var packet: ST.UT = undefined;
    ST.read(lr.reader(), &packet, ctx) catch |e| {
        if (e != error.EndOfStream) {
            lr.reader().skipBytes(lr.bytes_left, .{}) catch {};
        }
        return e;
    };
    return packet;
}

pub const PacketFrame = struct {
    id: u7,
    data: []u8,

    pub fn parse(self: PacketFrame, comptime ST: type, ctx: anytype) !ST.UT {
        var stream = std.io.fixedBufferStream(self.data);
        var packet: ST.TargetSpec.UT = undefined;
        try ST.TargetSpec.read(
            stream.reader(),
            &packet,
            ctx,
            try std.meta.intToEnum(ST.SourceSpec.UT, self.id),
        );
        return packet;
    }
    pub fn read(reader: anytype, a: Allocator) !PacketFrame {
        var len_: i32 = undefined;
        try VarI32.read(reader, &len_, .{});
        //std.debug.print("len: {}\n", .{len_});
        var id: u7 = undefined;
        try VarInt(u7).read(reader, &id, .{});
        //std.debug.print("id: {} ({})\n", .{ id, VarInt(u7).size(id) });
        const len = (math.cast(usize, len_) orelse return error.InvalidLength) -
            VarInt(u7).size(id, .{});
        const data = try a.alloc(u8, len);
        errdefer a.free(data);
        try reader.readNoEof(data);
        return .{
            .id = id,
            .data = data,
        };
    }
    pub fn write(self: PacketFrame, writer: anytype) !void {
        try VarI32.write(
            writer,
            @intCast(self.data.len + VarInt(u7).size(self.id, .{})),
            .{},
        );
        try VarInt(u7).write(writer, self.id, .{});
        try writer.writeAll(self.data);
    }
    pub fn deinit(self: *PacketFrame, a: Allocator) void {
        a.free(self.data);
        self.* = undefined;
    }
};

pub fn writePacket(
    comptime ST: type,
    writer: anytype,
    packet: ST.UT,
    ctx: anytype,
) !void {
    const packet_size = ST.size(packet, ctx);
    try VarI32.write(writer, @intCast(packet_size), ctx);
    var cr = std.io.countingWriter(writer);
    ST.write(cr.writer(), packet, ctx) catch |e| {
        writer.writeByteNTimes(
            0xAA,
            packet_size - @as(usize, @intCast(cr.bytes_written)),
        ) catch {};
        return e;
    };
}
