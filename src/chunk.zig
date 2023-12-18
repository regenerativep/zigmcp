const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const serde = @import("serde.zig");

const BitSet = @import("mcserde.zig").BitSet;

const VarI32 = @import("varint.zig").VarInt(i32);
const nbt = @import("nbt.zig");

const generated = @import("mcp-generated");
pub const Block = generated.Block;
pub const BlockState = generated.BlockState;
pub const Biome = generated.Biome;

const MaxNbtDepth = @import("main.zig").MaxNbtDepth;

// TODO: making this [-64,384) requires changing heightmaps impl
//     (are heightmap values signed?)
pub const MIN_Y = 0;
pub const HEIGHT = 256;
pub const MAX_Y = MIN_Y + HEIGHT;
pub const TOTAL_CHUNK_SECTIONS = HEIGHT / 16;

pub const BlockY = math.IntFittingRange(MIN_Y, MAX_Y);
pub const BiomeY = math.IntFittingRange(MIN_Y >> 2, MAX_Y >> 2);

const blockFields = @typeInfo(Block).Enum.fields;
pub fn blockStateIdRangeForBlock(
    block: Block,
) struct {
    from: BlockState.Id,
    to: BlockState.Id,
} {
    const to_ind = @intFromEnum(block);
    return .{
        .from = Block.defaultStateId(block),
        .to = if (to_ind < Block.MaxId)
            (Block.defaultStateId(@field(Block, blockFields[to_ind + 1].name)) - 1)
        else
            Block.MaxId,
    };
}
pub fn isBlock(comptime block: Block, bsid: BlockState.Id) bool {
    const range = comptime blockStateIdRangeForBlock(block);
    return bsid >= range.from and bsid <= range.to;
}

pub fn blockIsMotionBlocking(bsid: BlockState.Id) bool {
    inline for (.{
        .air,
        .void_air,
        .cave_air,
        .bamboo_sapling,
        .cactus,
        .water,
        .lava,
    }) |block| {
        if (isBlock(block, bsid)) return true;
    }
    return false;
}
pub fn isAir(bsid: BlockState.Id) bool {
    inline for (.{
        .air, .void_air, .cave_air,
    }) |block| {
        if (isBlock(block, bsid)) return true;
    }
    return false;
}
pub fn blockIsWorldSurface(bsid: BlockState.Id) bool {
    return !isAir(bsid);
}

pub const BlockEntityData = serde.Struct(struct {
    type: VarI32,
    nbt: nbt.Named(null, nbt.Dynamic(.any, MaxNbtDepth)),
});
pub const BlockEntity = serde.Struct(struct {
    xz: packed struct(u8) {
        z: u4,
        x: u4,
    },
    y: i16,
    data: BlockEntityData,
});

fn allEql(arr: anytype, value: std.meta.Child(@TypeOf(arr))) bool {
    const T = std.meta.Child(@TypeOf(arr));
    const V = @Vector(arr.len, T);
    return @reduce(.And, @as(V, arr) == @as(V, @splat(value)));
}

pub const LightLevels = struct {
    pub const UT = @This();
    const LenSpec = serde.Constant(VarI32, 2048, null);
    const BIT_SET_LONG_COUNT = BitSet.longCount(TOTAL_CHUNK_SECTIONS + 2);
    const BitSetLenSpec = serde.Constant(VarI32, BIT_SET_LONG_COUNT, null);
    pub const ArrayLenSpec = serde.RestrictInt(
        serde.Casted(VarI32, usize),
        .{ .max = TOTAL_CHUNK_SECTIONS + 2 },
    );

    pub const Level = u4;

    pub const Section = union(enum) {
        single: Level,
        direct: [2048]u8,

        pub fn set(
            self: *Section,
            x: BlockAxis,
            z: BlockAxis,
            y: BlockAxis,
            level: Level,
        ) void {
            const ind = axisToIndex(BlockAxis, x, z, y);
            switch (self.*) {
                .single => |d| if (d != level) {
                    self.* = .{ .direct = undefined };
                    @memset(&self.direct, d);
                    self.directSet(ind, level);
                },
                .direct => self.directSet(ind, level),
            }
        }
        pub fn get(self: *Section, x: BlockAxis, z: BlockAxis, y: BlockAxis) Level {
            const ind = axisToIndex(BlockAxis, x, z, y);
            return switch (self.*) {
                .single => |d| d,
                .direct => |d| @truncate(
                    d[ind >> 1] >> (@as(u1, @truncate(ind)) * @as(u3, 4)),
                ),
            };
        }
        fn directSet(self: *Section, ind: AxisIndex(BlockAxis), level: Level) void {
            const mask = @as(u8, 0xF) << (@as(u1, @truncate(ind)) * @as(u3, 4));
            self.direct[ind >> 1] &= ~mask;
            self.direct[ind >> 1] |=
                @as(u8, level) << (@as(u1, @truncate(ind)) * @as(u3, 4));
        }
    };

    block: [TOTAL_CHUNK_SECTIONS + 2]Section =
        [_]Section{.{ .single = 0xF }} ** (TOTAL_CHUNK_SECTIONS + 2),
    sky: [TOTAL_CHUNK_SECTIONS + 2]Section =
        [_]Section{.{ .single = 0xF }} ** (TOTAL_CHUNK_SECTIONS + 2),

    const longs_init = [_]u64{0} ** BIT_SET_LONG_COUNT;
    pub fn write(writer: anytype, in: UT) !void {
        var longs = longs_init;
        var mask = BitSet{ .data = &longs };

        // sky light mask
        var sky_light_count: i32 = 0;
        for (&in.sky, 0..) |section, i|
            if (section != .single or section.single != 0x0) {
                mask.set(i);
                sky_light_count += 1;
            };
        try BitSet.write(writer, mask);

        // block light mask
        longs = longs_init;
        var block_light_count: i32 = 0;
        for (&in.block, 0..) |section, i|
            if (section != .single or section.single != 0x0) {
                mask.set(i);
                block_light_count += 1;
            };
        try BitSet.write(writer, mask);

        // empty sky light mask
        longs = longs_init;
        for (&in.sky, 0..) |section, i|
            if (section == .single and section.single == 0x0)
                mask.set(i);
        try BitSet.write(writer, mask);

        // empty block light mask
        longs = longs_init;
        for (&in.block, 0..) |section, i|
            if (section == .single and section.single == 0x0)
                mask.set(i);
        try BitSet.write(writer, mask);

        // sky light array
        try VarI32.write(writer, sky_light_count);
        for (&in.sky) |section| switch (section) {
            .single => |d| if (d != 0x0) {
                try LenSpec.write(writer, undefined);
                try writer.writeByteNTimes(@as(u8, d) * 17, 2048);
            },
            .direct => |d| {
                try LenSpec.write(writer, undefined);
                try writer.writeAll(&d);
            },
        };

        // block light array
        try VarI32.write(writer, block_light_count);
        for (&in.block) |section| switch (section) {
            .single => |d| if (d != 0x0) {
                try LenSpec.write(writer, undefined);
                try writer.writeByteNTimes(@as(u8, d) * 17, 2048);
            },
            .direct => |d| {
                try LenSpec.write(writer, undefined);
                try writer.writeAll(&d);
            },
        };
    }
    pub fn read(reader: anytype, out: *UT, _: Allocator) !void {
        // sky light mask
        try BitSetLenSpec.read(reader, undefined, undefined);
        var sky_longs = longs_init;
        var sky_bits: BitSet = undefined;
        try BitSet.readWithBuffer(
            reader,
            &sky_bits,
            &sky_longs,
            undefined,
        );

        // block light mask
        try BitSetLenSpec.read(reader, undefined, undefined);
        var block_longs = longs_init;
        var block_bits: BitSet = undefined;
        try BitSet.readWithBuffer(
            reader,
            &block_bits,
            &block_longs,
            undefined,
        );

        // empty sky light mask
        try BitSetLenSpec.read(reader, undefined, undefined);
        var empty_sky_longs = longs_init;
        var empty_sky_bits: BitSet = undefined;
        try BitSet.readWithBuffer(
            reader,
            &empty_sky_bits,
            &empty_sky_longs,
            undefined,
        );

        // empty sky light mask
        try BitSetLenSpec.read(reader, undefined, undefined);
        var empty_block_longs = longs_init;
        var empty_block_bits: BitSet = undefined;
        try BitSet.readWithBuffer(
            reader,
            &empty_block_bits,
            &empty_block_longs,
            undefined,
        );

        for (&out.sky) |*section| section.* = .{ .single = 0x0 };
        for (&out.block) |*section| section.* = .{ .single = 0x0 };

        var len: usize = undefined;
        try ArrayLenSpec.read(reader, &len, undefined);
        for (&out.sky, 0..) |*section, i| if (sky_bits.get(i)) {
            try LenSpec.read(reader, undefined, undefined);
            section.* = .{ .direct = undefined };
            try reader.readNoEof(&section.direct);
            const val = @as(u8, @as(u4, @truncate(section.direct[0]))) * 17;
            if (allEql(section.direct, val))
                section.* = .{ .single = @truncate(section.direct[0]) };
        };

        try ArrayLenSpec.read(reader, &len, undefined);
        for (&out.block, 0..) |*section, i| if (block_bits.get(i)) {
            try LenSpec.read(reader, undefined, undefined);
            section.* = .{ .direct = undefined };
            try reader.readNoEof(&section.direct);
            const val = @as(u8, @as(u4, @truncate(section.direct[0]))) * 17;
            if (allEql(section.direct, val))
                section.* = .{ .single = @truncate(section.direct[0]) };
        };
    }
    pub fn size(self: UT) usize {
        var sky_sections: usize = 0;
        for (&self.sky) |section| {
            if (section != .single or section.single != 0x0) sky_sections += 1;
        }
        var block_sections: usize = 0;
        for (&self.block) |section| {
            if (section != .single or section.single != 0x0) block_sections += 1;
        }
        return BitSet.size(
            .{ .data = &([_]u64{undefined} ** BIT_SET_LONG_COUNT) },
        ) * 4 + ArrayLenSpec.size(sky_sections) + ArrayLenSpec.size(block_sections) +
            (sky_sections * (LenSpec.size(undefined) + 2048)) +
            (block_sections * (LenSpec.size(undefined) + 2048));
    }
    pub fn deinit(self: *UT, _: Allocator) void {
        self.* = undefined;
    }
};

test "light levels" {
    try serde.doTestOnValue(LightLevels, .{}, false);
}

pub const Column = struct {
    sections: [TOTAL_CHUNK_SECTIONS]ChunkSection.UT = [_]ChunkSection.UT{.{
        .block_count = 0,
        .blocks = .{ .single = Block.air.defaultStateId() },
        //.biomes = .{ .single = @intFromEnum(Biome.plains) },
        .biomes = .{ .single = 0 },
    }} ** TOTAL_CHUNK_SECTIONS,
    block_entities: std.AutoHashMapUnmanaged(
        struct { x: BlockAxis, z: BlockAxis, y: BlockY },
        BlockEntityData.UT,
    ) = .{},
    motion_blocking: HeightMap = .{},
    world_surface: HeightMap = .{},

    light_levels: LightLevels = .{},

    pub fn initFlat() Column {
        var self = Column{};
        for (&[_]Block{
            .bedrock, .stone, .stone, .stone,
            .stone,   .stone, .stone, .stone,
            .dirt,    .dirt,  .dirt,  .grass_block,
        }, 0..) |block, i| {
            const y = @as(BlockY, @intCast(i)) + MIN_Y;
            for (0..16) |z| for (0..16) |x|
                self.setBlock(@intCast(x), @intCast(z), y, block.defaultStateId());
        }
        return self;
    }

    pub fn deinit(self: *Column, a: Allocator) void {
        var iter = self.block_entities.valueIterator();
        while (iter.next()) |e| BlockEntityData.deinit(e, a);
        self.block_entities.deinit(a);
        self.* = undefined;
    }

    pub fn blockAt(self: Column, x: BlockAxis, z: BlockAxis, y: BlockY) BlockState.Id {
        return if (y >= MIN_Y and y < MAX_Y)
            self.sections[y - MIN_Y >> 4].blocks.get(x, z, @truncate(y))
        else
            (BlockState{ .air = {} }).toId();
    }
    pub fn biomeAt(self: Column, x: BiomeAxis, z: BiomeAxis, y: BiomeY) Biome.Id {
        assert(y >= MIN_Y >> 2 and y < MAX_Y >> 2);
        return self.sections[y - MIN_Y >> 2].blocks.get(x, z, @truncate(y));
    }
    pub fn setBlock(
        self: *Column,
        x: BlockAxis,
        z: BlockAxis,
        y: BlockY,
        value: BlockState.Id,
    ) void {
        assert(y >= MIN_Y and y < MAX_Y);
        const section = &self.sections[y - MIN_Y >> 4];
        const last_air = isAir(section.blocks.get(x, z, @truncate(y)));
        const new_air = isAir(value);
        section.blocks.set(x, z, @truncate(y), value);

        if (last_air and !new_air) {
            section.block_count += 1;
        } else if (!last_air and new_air) {
            section.block_count -= 1;
        }

        if (blockIsMotionBlocking(value) and self.motion_blocking.get(x, z) < y + 1)
            self.motion_blocking.set(x, z, y + 1);
        if (blockIsWorldSurface(value) and self.world_surface.get(x, z) < y + 1)
            self.world_surface.set(x, z, y + 1);
    }
    pub fn setBiome(
        self: *Column,
        x: BiomeAxis,
        z: BiomeAxis,
        y: BiomeY,
        value: Biome.Id,
    ) void {
        assert(y >= MIN_Y >> 2 and y < MAX_Y >> 2);
        return self.sections[y - MIN_Y >> 2].biomes.set(x, z, @truncate(y), value);
    }

    // warning: this fn is slow
    pub fn createHeightMap(
        self: Column,
        comptime kind: enum { motion_blocking, world_surface },
    ) HeightMap {
        var map = HeightMap{};
        for (0..16) |z| for (0..16) |x| {
            var y: BlockY = MAX_Y - 1;
            while (true) {
                const block = self.blockAt(@intCast(x), @intCast(z), y);
                if (switch (kind) {
                    .motion_blocking => blockIsMotionBlocking(block),
                    .world_surface => blockIsWorldSurface(block),
                }) {
                    map.set(@intCast(x), @intCast(z), y);
                    break;
                }
                if (self.sections[y - MIN_Y >> 4].blocks == .single) {
                    y -= 15;
                }

                if (y <= MIN_Y) {
                    break;
                } else {
                    y -= 1;
                }
            }
        };
        return map;
    }
};

pub const HeightMap = struct {
    pub const len = math.divCeil(usize, 256, @divTrunc(64, 9)) catch unreachable;
    pub const LenSpec = serde.Constant(serde.Num(i32, .big), @intCast(len), null);
    pub const ListSpec = serde.Array([len]u64);

    data: ListSpec.UT = [_]u64{0} ** len,

    pub const UT = @This();
    pub const E = ListSpec.E;

    pub fn write(writer: anytype, in: UT) !void {
        try LenSpec.write(writer, undefined);
        try ListSpec.write(writer, in.data);
    }
    pub fn read(reader: anytype, out: *UT, _: Allocator) !void {
        try LenSpec.read(reader, undefined, undefined);
        try ListSpec.read(reader, &out.data, undefined);
    }
    pub fn size(self: UT) usize {
        return LenSpec.size(undefined) + ListSpec.size(self.data);
    }
    pub fn deinit(self: *UT, _: Allocator) void {
        ListSpec.deinit(&self.data, undefined);
    }

    pub fn initAll(value: u9) Self {
        var part: u64 = 0;
        for (0..7) |_| {
            part |= @as(u64, value);
            part <<= 9;
        }
        part <<= 1;
        var self: Self = undefined;
        for (0..36) |i| self.data[i] = part;
        self.data[36] = (part << (9 * 5)) >> (9 * 5);
        return self;
    }

    const Self = @This();
    pub fn set(self: *Self, x: u4, z: u4, value: u9) void {
        return self.setIndex((@as(u8, z) << 4) + x, value);
    }
    pub fn get(self: Self, x: u4, z: u4) u9 {
        return self.getIndex((@as(u8, z) << 4) + x);
    }

    const mask_ = ~(~@as(u64, 0) << 9);
    pub fn setIndex(self: *Self, index: u8, value: u9) void {
        const shift = 9 * @as(std.math.Log2Int(u64), @intCast(index % 7)) + 1;
        const mask = ~(mask_ << shift);
        const long_ind = index / 7;
        self.data[long_ind] &= mask;
        self.data[long_ind] |= @as(u64, value) << shift;
    }
    pub fn getIndex(self: Self, index: u8) u9 {
        const shift = 9 * @as(std.math.Log2Int(u64), @intCast(index % 7)) + 1;
        const long_ind = index / 7;
        return @truncate(self.data[long_ind] >> shift);
    }
};
test "heightmap" {
    var m = HeightMap.initAll(1);
    for (0..256) |i| m.setIndex(@intCast(i), @intCast(i));
    for (0..256) |i| try testing.expectEqual(@as(u9, @intCast(i)), m.getIndex(@intCast(i)));
}

pub const ChunkSection = serde.Struct(struct {
    block_count: serde.Casted(i16, u16),
    blocks: PalettedContainer(.block),
    biomes: PalettedContainer(.biome),
});

pub fn PackedArray(comptime max_bits: comptime_int, comptime Count: comptime_int) type {
    return struct {
        pub const Index = std.math.IntFittingRange(0, Count - 1);
        pub const MaxLongCount =
            math.divCeil(usize, Count, @divTrunc(64, max_bits)) catch
            unreachable;
        pub const Bits = std.math.IntFittingRange(0, max_bits);
        pub const Value =
            @Type(.{ .Int = .{ .signedness = .unsigned, .bits = max_bits } });
        pub const LongIndex = std.math.IntFittingRange(0, MaxLongCount - 1);

        pub inline fn longCount(
            bits: Bits,
        ) std.math.IntFittingRange(0, MaxLongCount) {
            return @intCast(
                math.divCeil(usize, Count, @divTrunc(64, @as(usize, bits))) catch
                    unreachable,
            );
        }
        pub fn longSlice(self: *@This()) []u64 {
            return self.data[0..@This().longCount(self.bits)];
        }
        pub fn constLongSlice(self: *const @This()) []const u64 {
            return self.data[0..@This().longCount(self.bits)];
        }
        pub inline fn longIndex(bits: Bits, index: Index) LongIndex {
            return @intCast(@as(usize, index) / (64 / @as(usize, bits)));
        }
        pub inline fn lowIndex(bits: Bits, index: Index) ShiftInt {
            return @intCast(@as(usize, index) % (64 / @as(usize, bits)));
        }

        bits: Bits,
        data: [MaxLongCount]u64,

        const ShiftInt = math.Log2Int(u64);

        pub fn init(bits: Bits) @This() {
            return .{
                .bits = bits,
                .data = [_]u64{0} ** MaxLongCount,
            };
        }

        pub fn set(self: *@This(), index: Index, value: Value) void {
            return self.setInArray(self.bits, index, value);
        }
        pub inline fn setInArray(
            self: *@This(),
            bits: Bits,
            index: Index,
            value: Value,
        ) void {
            const shift: ShiftInt = @intCast(lowIndex(bits, index) * bits);
            const mask = ~(~@as(u64, 0) << @as(ShiftInt, @intCast(bits)));
            const long_index = longIndex(bits, index);
            self.data[long_index] &= ~(mask << shift);
            self.data[long_index] |= @as(u64, value) << shift;
        }
        pub fn get(self: *const @This(), index: Index) Value {
            return self.getInArray(self.bits, index);
        }
        pub inline fn getInArray(
            self: *const @This(),
            bits: Bits,
            index: Index,
        ) Value {
            const shift: ShiftInt = @intCast(lowIndex(bits, index) * bits);
            const mask = ~(~@as(u64, 0) << @as(ShiftInt, @intCast(bits)));
            return @intCast(
                (self.data[longIndex(bits, index)] >> shift) & mask,
            );
        }

        pub fn changeBits(self: *@This(), target_bits: Bits) void {
            assert(target_bits <= max_bits);
            if (target_bits > self.bits) {
                var i: Index = Count - 1;
                while (true) {
                    const val = self.getInArray(self.bits, i);
                    self.setInArray(target_bits, i, val);
                    if (i == 0) break;
                    i -= 1;
                }
            } else {
                var i: Index = 0;
                while (true) {
                    const val = self.getInArray(self.bits, i);
                    self.setInArray(self.bits, i, 0);
                    self.setInArray(target_bits, i, val);
                    if (i == Count - 1) break;
                    i += 1;
                }
            }
            self.bits = target_bits;
        }
    };
}

test "packed array" {
    const Arr = PackedArray(16, 4096);
    var arr = Arr.init(15);
    for (0..4096) |i| {
        arr.set(@intCast(i), @intCast(i));
    }
    for (0..4096) |i| {
        try testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
    arr.changeBits(16);
    for (0..4096) |i| {
        try testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
    for (0..4096) |i| {
        arr.set(@intCast(i), @intCast(i));
    }
    for (0..4096) |i| {
        try testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
    arr.changeBits(12);
    for (0..4096) |i| {
        try testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
    for (0..4096) |i| {
        arr.set(@intCast(i), @intCast(i));
    }
    for (0..4096) |i| {
        try testing.expectEqual(@as(Arr.Value, @intCast(i)), arr.get(@intCast(i)));
    }
}

pub const BlockAxis = u4;
pub const BiomeAxis = u2;
pub fn AxisIndex(comptime Axis: type) type {
    return @Type(.{ .Int = .{
        .signedness = .unsigned,
        .bits = @typeInfo(Axis).Int.bits * 3,
    } });
}
pub inline fn axisToIndex(
    comptime Axis: type,
    x: Axis,
    z: Axis,
    y: Axis,
) AxisIndex(Axis) {
    const Index = AxisIndex(Axis);
    const one_shift: comptime_int = @intCast(@typeInfo(Axis).Int.bits);
    return (@as(Index, y) << (one_shift * 2)) |
        (@as(Index, z) << one_shift) |
        @as(Index, x);
}

pub fn PalettedContainer(comptime kind: enum { block, biome }) type {
    return union(enum) {
        pub const Count = switch (kind) {
            .block => 4096,
            .biome => 64,
        };
        pub const Index = switch (kind) {
            .block => u12,
            .biome => u6,
        };
        pub const Axis = switch (kind) {
            .block => BlockAxis,
            .biome => BiomeAxis,
        };
        pub const Id = switch (kind) {
            .block => BlockState.Id,
            .biome => Biome.Id,
        };
        pub const IdBits = @as(comptime_int, @intCast(@typeInfo(Id).Int.bits));
        pub const IndirectId = switch (kind) {
            .block => u8,
            .biome => u3,
        };
        pub const MaxIndirectBits = switch (kind) {
            .block => 8,
            .biome => 3,
        };
        pub const MaxDirectBits = switch (kind) {
            .block => 16,
            .biome => 8,
        };
        pub const MaxIndirectPaletteLength = math.maxInt(IndirectId) + 1;
        pub const IndirectPaletteLen =
            std.math.IntFittingRange(0, MaxIndirectPaletteLength);

        pub const IndirectData = PackedArray(MaxIndirectBits, Count);
        pub const PaletteData = std.BoundedArray(Id, MaxIndirectPaletteLength);
        pub const DirectData = PackedArray(16, Count);

        single: Id,
        indirect: struct {
            palette: PaletteData,
            data: IndirectData,
        },
        direct: DirectData,

        pub const UT = @This();
        pub const E = VarI32.E || error{
            InvalidConstant,
            EndOfStream,
            InvalidBits,
            InvalidCast,
            InvalidLength,
        };

        const Self = @This();
        pub fn upgrade(self: *Self) void {
            switch (self.*) {
                .single => |id| self.* = .{ .indirect = .{
                    .palette = PaletteData.fromSlice(&.{id}) catch unreachable,
                    .data = IndirectData.init(4),
                } },
                .indirect => |d| {
                    var direct = DirectData.init(IdBits);
                    for (0..Count) |i| {
                        direct.set(
                            @intCast(i),
                            d.palette.constSlice()[d.data.get(@intCast(i))],
                        );
                    }
                    self.* = .{ .direct = direct };
                },
                else => {},
            }
        }
        pub fn set(self: *Self, x: Axis, z: Axis, y: Axis, value: Id) void {
            const index = axisToIndex(Axis, x, z, y);
            switch (self.*) {
                .single => |id| if (value != id) {
                    self.upgrade(); // upgrade to indirect
                    const palette_id = self.indirect.palette.len;
                    self.indirect.palette.appendAssumeCapacity(value);
                    self.indirect.data.set(index, @intCast(palette_id));
                },
                .indirect => |*d| {
                    const palette_id: IndirectPaletteLen =
                        for (d.palette.slice(), 0..) |id, i|
                    {
                        if (id == value)
                            break @intCast(i);
                    } else d.palette.len;
                    //std.debug.print("value: {}, palette id: {}\n", .{ value, palette_id });
                    if (palette_id == d.palette.len) {
                        d.palette.append(value) catch {
                            self.upgrade(); // upgrade to direct
                            self.direct.set(index, value);
                            return;
                        };
                        if (d.palette.len > (@as(usize, 1) << @intCast(d.data.bits))) {
                            d.data.changeBits(d.data.bits + 1);
                        }
                    }
                    d.data.set(index, @intCast(palette_id));
                },
                .direct => |*d| {
                    if (IdBits - @clz(value) > d.bits)
                        d.changeBits(IdBits - @clz(value));
                    d.set(index, value);
                },
            }
        }
        pub fn get(self: Self, x: Axis, z: Axis, y: Axis) Id {
            const index = axisToIndex(Axis, x, z, y);
            return switch (self) {
                .single => |id| id,
                .indirect => |d| d.palette.get(@intCast(d.data.get(index))),
                .direct => |d| @intCast(d.get(index)),
            };
        }

        pub fn write(writer: anytype, in: UT) !void {
            switch (in) {
                .single => |id| {
                    try writer.writeByte(0);
                    try VarI32.write(writer, @intCast(id));
                    try VarI32.write(writer, 0);
                },
                .indirect => |d| {
                    try writer.writeByte(d.data.bits);
                    try VarI32.write(writer, @intCast(d.palette.len));
                    for (d.palette.slice()) |item|
                        try VarI32.write(writer, @intCast(item));
                    const longs = d.data.constLongSlice();
                    try VarI32.write(writer, @intCast(longs.len));
                    for (longs) |item| try serde.Num(u64, .big).write(writer, item);
                },
                .direct => |d| {
                    try writer.writeByte(d.bits);
                    const longs = d.constLongSlice();
                    try VarI32.write(writer, @intCast(longs.len));
                    for (longs) |item| try serde.Num(u64, .big).write(writer, item);
                },
            }
        }

        pub fn read(reader: anytype, out: *UT, _: Allocator) !void {
            var bits: u8 = undefined;
            try serde.Num(u8, .big).read(reader, &bits, undefined);
            switch (bits) {
                0 => {
                    out.* = .{ .single = undefined };
                    try serde.Casted(VarI32, Id).read(reader, &out.single, undefined);
                    try serde.Constant(VarI32, 0, null).read(reader, undefined, undefined);
                },
                1...MaxIndirectBits => {
                    out.* = .{ .indirect = .{
                        .palette = .{},
                        .data = IndirectData.init(@intCast(bits)),
                    } };
                    try serde.Casted(VarI32, IndirectPaletteLen).read(
                        reader,
                        &out.indirect.palette.len,
                        undefined,
                    );
                    for (out.indirect.palette.slice()) |*item|
                        try serde.Casted(VarI32, Id).read(reader, item, undefined);

                    var read_long_len: u32 = undefined;
                    try serde.Casted(VarI32, u32).read(
                        reader,
                        &read_long_len,
                        undefined,
                    );
                    for (out.indirect.data.longSlice()) |*item|
                        try serde.Num(u64, .big).read(reader, item, undefined);
                },
                MaxIndirectBits + 1...MaxDirectBits => {
                    var read_long_len: u32 = undefined;
                    try serde.Casted(VarI32, u32).read(reader, &read_long_len, undefined);
                    out.* = .{ .direct = DirectData.init(@intCast(bits)) };
                    for (out.direct.longSlice()) |*item|
                        try serde.Num(u64, .big).read(reader, item, undefined);
                },
                else => return error.InvalidBits,
            }
        }
        pub fn deinit(self: *UT, _: Allocator) void {
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            switch (self) {
                .single => |id| return 1 + VarI32.size(@intCast(id)) + VarI32.size(0),
                .indirect => |d| {
                    const longs = d.data.constLongSlice();
                    var total =
                        1 + VarI32.size(@intCast(d.palette.len)) +
                        VarI32.size(@intCast(longs.len));
                    for (d.palette.slice()) |item|
                        total += VarI32.size(@intCast(item));
                    for (longs) |item|
                        total += serde.Num(u64, .big).size(item);
                    return total;
                },
                .direct => |d| {
                    const longs = d.constLongSlice();
                    var total = 1 + VarI32.size(@intCast(longs.len));
                    for (longs) |item| total += serde.Num(u64, .big).size(item);
                    return total;
                },
            }
        }
    };
}

test "paletted container" {
    const ST = PalettedContainer(.block);
    var cont = ST{ .single = 0 };
    try serde.doTestOnValue(ST, cont, false);
    for (0..16) |y| for (0..16) |z| for (0..16) |x| {
        cont.set(@intCast(x), @intCast(z), @intCast(y), @as(u4, @intCast(x)));
    };
    try testing.expect(cont == .indirect);
    for (0..16) |y| for (0..16) |z| for (0..16) |x| {
        try testing.expectEqual(
            @as(ST.Id, @as(u4, @intCast(x))),
            cont.get(@intCast(x), @intCast(z), @intCast(y)),
        );
    };
    try serde.doTestOnValue(ST, cont, false);
    for (0..16) |y| for (0..16) |z| for (0..16) |x| {
        cont.set(
            @intCast(x),
            @intCast(z),
            @intCast(y),
            axisToIndex(ST.Axis, @intCast(x), @intCast(z), @intCast(y)),
        );
    };
    try testing.expect(cont == .direct);
    for (0..16) |y| for (0..16) |z| for (0..16) |x| {
        try testing.expectEqual(
            @as(ST.Id, axisToIndex(ST.Axis, @intCast(x), @intCast(z), @intCast(y))),
            cont.get(@intCast(x), @intCast(z), @intCast(y)),
        );
    };
    try serde.doTestOnValue(ST, cont, false);
}
