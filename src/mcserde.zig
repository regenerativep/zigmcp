const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const Uuid6 = @import("uuid6");

const serde = @import("serde.zig");
const PrefixedArray = serde.PrefixedArray;

const VarI32 = @import("varint.zig").VarInt(i32);

pub const BitSet = struct {
    pub const ListSpec = PrefixedArray(VarI32, u64, .{});

    pub const E = ListSpec.E;
    pub const UT = @This();

    data: []const u64,

    pub fn write(writer: anytype, in: UT) !void {
        try ListSpec.write(writer, in.data);
    }
    pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
        try ListSpec.read(reader, &out.data, a);
    }
    pub fn size(self: UT) usize {
        return ListSpec.size(self.data);
    }
    pub fn deinit(self: *UT, a: Allocator) void {
        ListSpec.deinit(&self.data, a);
    }

    pub inline fn longCount(bit_count: usize) usize {
        return (bit_count + 63) >> 6;
    }

    pub fn readWithBuffer(reader: anytype, out: *UT, data: []u64, a: Allocator) !void {
        try ListSpec.TargetSpec.readWithBuffer(reader, &out.data, data, a);
    }

    pub fn initEmpty(a: Allocator, bit_count: usize) UT {
        const data = try a.alloc(u64, longCount(bit_count));
        @memset(data, 0);
        return .{ .data = data };
    }
    pub fn get(self: UT, i: usize) bool {
        return (self.data[i >> 6] & (@as(u64, 1) << @as(u6, @truncate(i)))) != 0;
    }
    pub fn set(self: *UT, i: usize) void {
        @constCast(self.data)[i >> 6] |= @as(u64, 1) << @as(u6, @truncate(i));
    }
    pub fn unset(self: *UT, i: usize) void {
        @constCast(self.data)[i >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(i)));
    }
};

/// String serialization type, because the protocol works with codepoint counts, not byte counts
pub fn PString(comptime max_len_opt: ?comptime_int) type {
    return serde.Pass(
        serde.RestrictInt(serde.Casted(VarI32, usize), .{ .max = max_len_opt }),
        serde.CodepointArray,
    );
}

pub const Uuid = struct {
    pub const UT = Uuid6;
    pub const E = error{EndOfStream};
    pub fn write(writer: anytype, in: UT) !void {
        try writer.writeAll(&in.bytes);
    }
    pub fn read(reader: anytype, out: *UT, _: Allocator) !void {
        try reader.readNoEof(&out.bytes);
    }
    pub fn deinit(self: *UT, _: Allocator) void {
        self.* = undefined;
    }
    pub fn size(self: UT) usize {
        return self.bytes.len;
    }
    // stolen from https://github.com/regenerativep/zig-mc-server/blob/d82dc727311fd10d2e404ebb4715336637dcca97/src/mcproto.zig#L137
    // referenced https://github.com/AdoptOpenJDK/openjdk-jdk8u/blob/9a91972c76ddda5c1ce28b50ca38cbd8a30b7a72/jdk/src/share/classes/java/util/UUID.java#L153-L175
    pub fn fromUsername(username: []const u8) UT {
        assert(username.len <= 16);
        const ofp = "OfflinePlayer:";
        var buf = ofp.* ++ ([_]u8{undefined} ** 16);
        @memcpy(buf[ofp.len..][0..username.len], username);
        var uuid: UT = undefined;
        std.crypto.hash.Md5.hash(buf[0 .. ofp.len + username.len], &uuid.bytes, .{});
        uuid.setVersion(3);
        uuid.setVariant(.rfc4122);
        return uuid;
    }
};

pub const Angle = struct {
    pub usingnamespace serde.Num(u8, .big);
    pub fn fromF32(val: f32) u8 {
        return @intCast(@mod(@as(isize, @intFromFloat((val / 360.0) * 256.0)), 256));
    }
};

pub fn V3(comptime T: type) type {
    return struct { x: T, y: T, z: T };
}

pub const Position = packed struct(u64) {
    y: i12,
    z: i26,
    x: i26,
};
