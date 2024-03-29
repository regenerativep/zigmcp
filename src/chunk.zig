const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const serde = @import("serde.zig");

const BitSet = @import("mcserde.zig").BitSet(TOTAL_SECTIONS_MAXIMUM + 2);

const VarI32 = @import("varint.zig").VarInt(i32);
const nbt = @import("nbt.zig");

const mcv = @import("main.zig").vlatest;

const generated = @import("mcp-generated");
pub const Block = generated.Block;
pub const BlockState = generated.BlockState;
pub const Biome = generated.Biome;

const MaxNbtDepth = @import("main.zig").MaxNbtDepth;

// https://minecraft.fandom.com/wiki/Custom#JSON_format
//     Range for MIN_Y is [-2032, 2016], HEIGHT is [16, 4064]
//     MIN_Y and HEIGHT must be a multiple of 16
// TODO: is that mention about max build height another limit to be concerned about or
//     is that only the combination of the MIN_Y and HEIGHT?
pub const MIN_Y_MINIMUM = -2032;
pub const MIN_Y_MAXIMUM = 2016;
pub const HEIGHT_MINIMUM = 16;
pub const HEIGHT_MAXIMUM = 4064;
pub const MAX_Y_MINIMUM = MIN_Y_MINIMUM + HEIGHT_MINIMUM;
pub const MAX_Y_MAXIMUM = MIN_Y_MAXIMUM + HEIGHT_MAXIMUM;

pub const TOTAL_SECTIONS_MINIMUM = @divExact(HEIGHT_MINIMUM, 16);
pub const TOTAL_SECTIONS_MAXIMUM = @divExact(HEIGHT_MAXIMUM, 16);

pub const BIOME_MIN_Y_MINIMUM = @divExact(MIN_Y_MINIMUM, 4);
pub const BIOMY_MIN_Y_MAXIMUM = @divExact(MIN_Y_MAXIMUM, 4);
pub const BIOME_MAX_Y_MINIMUM = @divExact(MAX_Y_MINIMUM, 4);
pub const BIOME_MAX_Y_MAXIMUM = @divExact(MAX_Y_MAXIMUM, 4);
pub const BIOME_HEIGHT_MINIMUM = @divExact(HEIGHT_MINIMUM, 4);
pub const BIOME_HEIGHT_MAXIMUM = @divExact(HEIGHT_MAXIMUM, 4);

pub const BlockY = math.IntFittingRange(MIN_Y_MINIMUM, MAX_Y_MAXIMUM);
pub const UBlockY = math.IntFittingRange(0, HEIGHT_MAXIMUM);
pub const BiomeY = math.IntFittingRange(BIOME_MIN_Y_MINIMUM, BIOME_MAX_Y_MAXIMUM);
pub const UBiomeY = math.IntFittingRange(0, BIOME_HEIGHT_MAXIMUM);

pub inline fn blockYToU(y: BlockY, min_y: BlockY) UBlockY {
    return @intCast(y - min_y);
}
pub inline fn biomeYToU(y: BiomeY, min_y: BiomeY) UBiomeY {
    return @intCast(y - min_y);
}

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
        .air,            .void_air, .cave_air,
        .bamboo_sapling, .cactus,   .water,
        .lava,
    }) |block| {
        if (isBlock(block, bsid)) return false;
    }
    return true;
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
    pub const ArrayLenSpec = serde.RestrictInt(
        serde.Casted(VarI32, usize),
        .{ .max = TOTAL_SECTIONS_MAXIMUM + 2, .min = 0 },
    );
    pub const E = LenSpec.E || ArrayLenSpec.E || BitSet.E;

    pub const Level = u4;

    pub const Section = union(enum) {
        single: Level,
        direct: *[2048]u8,

        pub fn set(
            self: *Section,
            a: Allocator,
            x: BlockAxis,
            z: BlockAxis,
            y: BlockAxis,
            level: Level,
        ) !void {
            const ind = axisToIndex(BlockAxis, x, z, y);
            switch (self.*) {
                .single => |d| if (d != level) {
                    self.* = .{ .direct = try a.create([2048]u8) };
                    @memset(self.direct, d);
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
                    d.*[ind >> 1] >> (@as(u1, @truncate(ind)) * @as(u3, 4)),
                ),
            };
        }
        fn directSet(self: *Section, ind: AxisIndex(BlockAxis), level: Level) void {
            const mask = @as(u8, 0xF) << (@as(u1, @truncate(ind)) * @as(u3, 4));
            self.direct.*[ind >> 1] &= ~mask;
            self.direct.*[ind >> 1] |=
                @as(u8, level) << (@as(u1, @truncate(ind)) * @as(u3, 4));
        }

        pub fn deinit(self: *Section, a: Allocator) void {
            switch (self.*) {
                .single => {},
                .direct => |d| a.destroy(d),
            }
        }
    };

    block: []Section,
    sky: []Section,

    const Self = @This();

    /// initializes all light levels to the given value
    /// `section_count` is the number of sections (height / 16)
    pub fn initAll(a: Allocator, level: Level, section_count: usize) !Self {
        var self: Self = undefined;
        self.block = try a.alloc(Section, section_count + 2);
        errdefer a.free(self.block);
        self.sky = try a.alloc(Section, section_count + 2);
        errdefer a.free(self.sky);

        @memset(self.block, .{ .single = level });
        @memset(self.sky, .{ .single = level });
        return self;
    }

    pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
        // sky light mask
        var mask = BitSet.initEmpty(in.sky.len);
        var sky_light_count: i32 = 0;
        for (in.sky, 0..) |section, i|
            if (section != .single or section.single != 0x0) {
                mask.set(i);
                sky_light_count += 1;
            };
        try BitSet.write(writer, mask, ctx);

        // block light mask
        mask = BitSet.initEmpty(in.block.len);
        var block_light_count: i32 = 0;
        for (in.block, 0..) |section, i|
            if (section != .single or section.single != 0x0) {
                mask.set(i);
                block_light_count += 1;
            };
        try BitSet.write(writer, mask, ctx);

        // empty sky light mask
        mask = BitSet.initEmpty(in.sky.len);
        for (in.sky, 0..) |section, i|
            if (section == .single and section.single == 0x0)
                mask.set(i);
        try BitSet.write(writer, mask, ctx);

        // empty block light mask
        mask = BitSet.initEmpty(in.block.len);
        for (in.block, 0..) |section, i|
            if (section == .single and section.single == 0x0)
                mask.set(i);
        try BitSet.write(writer, mask, ctx);

        // sky light array
        try VarI32.write(writer, sky_light_count, ctx);
        for (in.sky) |section| switch (section) {
            .single => |d| if (d != 0x0) {
                try LenSpec.write(writer, undefined, ctx);
                try writer.writeByteNTimes(@as(u8, d) * 17, 2048);
            },
            .direct => |d| {
                try LenSpec.write(writer, undefined, ctx);
                try writer.writeAll(d);
            },
        };

        // block light array
        try VarI32.write(writer, block_light_count, ctx);
        for (in.block) |section| switch (section) {
            .single => |d| if (d != 0x0) {
                try LenSpec.write(writer, undefined, ctx);
                try writer.writeByteNTimes(@as(u8, d) * 17, 2048);
            },
            .direct => |d| {
                try LenSpec.write(writer, undefined, ctx);
                try writer.writeAll(d);
            },
        };
    }
    pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
        const section_count = @divExact(ctx.world.height, 16);

        // sky light mask
        var sky_bits: BitSet = undefined;
        try BitSet.read(reader, &sky_bits, ctx);

        // block light mask
        var block_bits: BitSet = undefined;
        try BitSet.read(reader, &block_bits, ctx);

        // empty sky light mask
        var empty_sky_bits: BitSet = undefined;
        try BitSet.read(reader, &empty_sky_bits, ctx);

        // empty sky light mask
        var empty_block_bits: BitSet = undefined;
        try BitSet.read(reader, &empty_block_bits, ctx);

        out.* = try Self.initAll(ctx.allocator, 0x0, section_count);
        errdefer out.deinit(ctx);

        var len: usize = undefined;
        try ArrayLenSpec.read(reader, &len, ctx);
        for (out.sky, 0..) |*section, i| if (sky_bits.get(i)) {
            try LenSpec.read(reader, undefined, ctx);
            section.* = .{ .direct = try ctx.allocator.create([2048]u8) };
            errdefer ctx.allocator.destroy(section.direct);
            try reader.readNoEof(section.direct);
            const val = @as(u8, @as(u4, @truncate(section.direct.*[0]))) * 17;
            if (allEql(section.direct.*, val)) {
                const direct = section.direct;
                section.* = .{ .single = @truncate(direct.*[0]) };
                ctx.allocator.destroy(direct);
            }
        };

        try ArrayLenSpec.read(reader, &len, ctx);
        for (out.block, 0..) |*section, i| if (block_bits.get(i)) {
            try LenSpec.read(reader, undefined, ctx);
            section.* = .{ .direct = try ctx.allocator.create([2048]u8) };
            errdefer ctx.allocator.destroy(section.direct);
            try reader.readNoEof(section.direct);
            const val = @as(u8, @as(u4, @truncate(section.direct.*[0]))) * 17;
            if (allEql(section.direct.*, val)) {
                const direct = section.direct;
                section.* = .{ .single = @truncate(direct.*[0]) };
                ctx.allocator.destroy(direct);
            }
        };
    }
    pub fn size(self: UT, ctx: anytype) usize {
        var sky_sections: usize = 0;
        for (self.sky) |section| {
            if (section != .single or section.single != 0x0) sky_sections += 1;
        }
        var block_sections: usize = 0;
        for (self.block) |section| {
            if (section != .single or section.single != 0x0) block_sections += 1;
        }
        return (BitSet.initEmpty(self.sky.len).size(ctx) * 2) +
            (BitSet.initEmpty(self.block.len).size(ctx) * 2) +
            ArrayLenSpec.size(sky_sections, ctx) +
            ArrayLenSpec.size(block_sections, ctx) +
            (sky_sections * (LenSpec.size(undefined, ctx) + 2048)) +
            (block_sections * (LenSpec.size(undefined, ctx) + 2048));
    }
    pub fn deinit(self: *UT, ctx: anytype) void {
        {
            var i = self.sky.len;
            while (i > 0) {
                i -= 1;
                self.sky[i].deinit(ctx.allocator);
            }
        }
        {
            var i = self.block.len;
            while (i > 0) {
                i -= 1;
                self.block[i].deinit(ctx.allocator);
            }
        }
        ctx.allocator.free(self.sky);
        ctx.allocator.free(self.block);
        self.* = undefined;
    }
};

test "light levels" {
    var levels = try LightLevels.initAll(testing.allocator, 0xF, 384 / 16);
    const ctx = mcv.Context{
        .allocator = testing.allocator,
        .world = .{ .height = 384 },
    };
    defer levels.deinit(ctx);
    try serde.doTestOnValue(LightLevels, levels, ctx);
}

pub const Column = struct {
    const DefaultChunkSection = ChunkSection.UT{
        .block_count = 0,
        .blocks = .{ .single = Block.air.defaultStateId() },
        .biomes = .{ .single = @intFromEnum(Biome.plains) },
    };

    sections: []ChunkSection.UT,
    block_entities: std.AutoHashMapUnmanaged(
        struct { x: BlockAxis, z: BlockAxis, y: BlockY },
        BlockEntityData.UT,
    ) = .{},
    motion_blocking: HeightMap,
    world_surface: HeightMap,

    light_levels: LightLevels,

    pub inline fn height(self: Column) UBlockY {
        return @intCast(self.sections.len * 16);
    }

    pub fn initFlat(a: Allocator, section_count: usize) !Column {
        const heightmap_bits = math.log2_int_ceil(usize, section_count * 16);
        var self = Column{
            .sections = try a.alloc(ChunkSection.UT, section_count),
            .motion_blocking = .{
                .inner = HeightMap.InnerArray.initAll(@intCast(heightmap_bits), 0),
            },
            .world_surface = .{
                .inner = HeightMap.InnerArray.initAll(@intCast(heightmap_bits), 0),
            },
            .light_levels = undefined,
        };
        errdefer a.free(self.sections);
        self.light_levels = try LightLevels.initAll(a, 0xF, section_count);
        errdefer self.light_levels.deinit(.{ .allocator = a });
        @memset(self.sections, DefaultChunkSection);
        var y: UBlockY = 0;
        for (&[_]Block{
            .bedrock, .stone, .stone, .stone,
            .stone,   .stone, .stone, .stone,
            .dirt,    .dirt,  .dirt,  .grass_block,
        }) |block| {
            for (0..16) |z| for (0..16) |x|
                self.setBlock(@intCast(x), @intCast(z), y, block.defaultStateId());
            y += 1;
        }
        return self;
    }

    pub fn deinit(self: *Column, a: Allocator) void {
        a.free(self.sections);
        self.light_levels.deinit(.{ .allocator = a });
        var iter = self.block_entities.valueIterator();
        while (iter.next()) |e| BlockEntityData.deinit(e, .{ .allocator = a });
        self.block_entities.deinit(a);
        self.* = undefined;
    }

    pub fn blockAt(self: Column, x: BlockAxis, z: BlockAxis, y: UBlockY) BlockState.Id {
        return if (y < self.height())
            self.sections[y >> 4].blocks
                .get(x, z, @truncate(y))
        else
            comptime BlockState.toId(.air);
    }

    pub fn biomeAt(self: Column, x: BiomeAxis, z: BiomeAxis, y: UBiomeY) Biome.Id {
        return if (y < self.height() >> 2)
            self.sections[y >> 2].blocks.get(x, z, @truncate(y))
        else
            @intFromEnum(Biome.the_void);
    }

    pub fn setBlock(
        self: *Column,
        x: BlockAxis,
        z: BlockAxis,
        y: UBlockY,
        value: BlockState.Id,
    ) void {
        if (y >= self.height()) return;
        const section = &self.sections[y >> 4];
        const last_air = isAir(section.blocks.get(x, z, @truncate(y)));
        const new_air = isAir(value);
        section.blocks.set(x, z, @truncate(y), value);

        // update heightmap while we're at it
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
        y: UBiomeY,
        value: Biome.Id,
    ) void {
        if (y >= self.height() >> 2) return;
        self.sections[y >> 2].biomes.set(x, z, @truncate(y), value);
    }
};

pub const HeightMap = struct {
    const Self = @This();

    pub const InnerArray =
        PackedArray(math.log2_int_ceil(usize, HEIGHT_MAXIMUM), 256, .right);
    pub const ListSpec = serde.PrefixedArray(
        serde.Num(i32, .big),
        serde.Num(u64, .big),
        .{ .max = 256 },
    );
    pub const InnerLengthSpec = ListSpec.SourceSpec;
    pub const InnerListSpec = ListSpec.TargetSpec;

    inner: InnerArray,

    pub const UT = @This();
    pub const E = ListSpec.E;

    pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
        try ListSpec.write(writer, in.inner.constLongSlice(), ctx);
    }
    pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
        const height = ctx.world.height;

        var len: InnerLengthSpec.UT = undefined;
        try InnerLengthSpec.read(reader, &len, ctx);
        var slice_: []const InnerListSpec.ElemSpec.UT = undefined;
        try InnerListSpec.readWithBuffer(
            reader,
            &slice_,
            out.inner.data[0..len],
            ctx,
        );
        out.inner.bits = math.log2_int_ceil(UBlockY, height + 1);
    }
    pub fn size(self: UT, ctx: anytype) usize {
        return ListSpec.size(self.inner.constLongSlice(), ctx);
    }
    pub fn deinit(self: *UT, _: anytype) void {
        self.* = undefined;
    }

    pub fn set(self: *Self, x: BlockAxis, z: BlockAxis, value: UBlockY) void {
        return self.inner.set(@as(u8, x) + (@as(u8, z) << 4), @intCast(value));
    }
    pub fn get(self: *Self, x: BlockAxis, z: BlockAxis) UBlockY {
        return @intCast(self.inner.get(@as(u8, x) + (@as(u8, z) << 4)));
    }
};
test "heightmap" {
    var m = HeightMap{ .inner = HeightMap.InnerArray.initAll(9, 1) };
    for (0..256) |i|
        m.inner.set(@intCast(i), @intCast(i));
    for (0..256) |i|
        try testing.expectEqual(@as(u9, @intCast(i)), m.inner.get(@intCast(i)));
}

pub const ChunkSection = serde.Struct(struct {
    block_count: serde.Casted(i16, u16),
    blocks: PalettedContainer(.block),
    biomes: PalettedContainer(.biome),
});

pub fn PackedArray(
    comptime max_bits: comptime_int,
    comptime count: comptime_int,
    comptime aligned: enum { left, right },
) type {
    return struct {
        const Self = @This();

        pub const Count = count;
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
        pub fn longSlice(self: *Self) []u64 {
            return self.data[0..Self.longCount(self.bits)];
        }
        pub fn constLongSlice(self: *const Self) []const u64 {
            return self.data[0..Self.longCount(self.bits)];
        }
        pub inline fn longIndex(bits: Bits, index: Index) LongIndex {
            return @intCast(@as(usize, index) / (64 / @as(usize, bits)));
        }
        pub inline fn lowIndex(bits: Bits, index: Index) ShiftInt {
            return @intCast(@as(usize, index) % (64 / @as(usize, bits)));
        }
        pub inline fn getShift(bits: Bits, index: Index) ShiftInt {
            return @intCast(lowIndex(bits, index) * bits + switch (aligned) {
                .left => @as(ShiftInt, @truncate(
                    @as(math.Log2IntCeil(u64), 64) % bits,
                )),
                .right => 0,
            });
        }

        bits: Bits,
        data: [MaxLongCount]u64,

        pub fn init(bits: Bits) Self {
            return .{
                .bits = bits,
                .data = [_]u64{0} ** MaxLongCount,
            };
        }

        pub fn initAll(bits: Bits, value: Value) Self {
            var self = Self.init(bits);
            for (0..Count) |i| {
                self.set(@intCast(i), value);
            }
            return self;
        }

        const ShiftInt = math.Log2Int(u64);
        pub fn set(self: *Self, index: Index, value: Value) void {
            return self.setInArray(self.bits, index, value);
        }
        pub inline fn setInArray(
            self: *Self,
            bits: Bits,
            index: Index,
            value: Value,
        ) void {
            const shift = getShift(bits, index);
            const mask = ~(~@as(u64, 0) << @as(ShiftInt, @intCast(bits)));
            const long_index = longIndex(bits, index);
            self.data[long_index] &= ~(mask << shift);
            self.data[long_index] |= @as(u64, value) << shift;
        }
        pub fn get(self: *const Self, index: Index) Value {
            return self.getInArray(self.bits, index);
        }
        pub inline fn getInArray(
            self: *const Self,
            bits: Bits,
            index: Index,
        ) Value {
            const shift = getShift(bits, index);
            const mask = ~(~@as(u64, 0) << @as(ShiftInt, @intCast(bits)));
            return @intCast(
                (self.data[longIndex(bits, index)] >> shift) & mask,
            );
        }

        pub fn changeBits(self: *Self, target_bits: Bits) void {
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
    const Arr = PackedArray(16, 4096, .right);
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

        pub const IndirectData = PackedArray(MaxIndirectBits, Count, .right);
        pub const PaletteData = std.BoundedArray(Id, MaxIndirectPaletteLength);
        pub const DirectData = PackedArray(16, Count, .right);

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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            switch (in) {
                .single => |id| {
                    try writer.writeByte(0);
                    try VarI32.write(writer, @intCast(id), ctx);
                    try VarI32.write(writer, 0, ctx);
                },
                .indirect => |d| {
                    try writer.writeByte(d.data.bits);
                    try VarI32.write(writer, @intCast(d.palette.len), ctx);
                    for (d.palette.slice()) |item|
                        try VarI32.write(writer, @intCast(item), ctx);
                    const longs = d.data.constLongSlice();
                    try VarI32.write(writer, @intCast(longs.len), ctx);
                    for (longs) |item|
                        try serde.Num(u64, .big).write(writer, item, ctx);
                },
                .direct => |d| {
                    try writer.writeByte(d.bits);
                    const longs = d.constLongSlice();
                    try VarI32.write(writer, @intCast(longs.len), ctx);
                    for (longs) |item|
                        try serde.Num(u64, .big).write(writer, item, ctx);
                },
            }
        }

        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            var bits: u8 = undefined;
            try serde.Num(u8, .big).read(reader, &bits, ctx);
            switch (bits) {
                0 => {
                    out.* = .{ .single = undefined };
                    try serde.Casted(VarI32, Id).read(reader, &out.single, ctx);
                    try serde.Constant(VarI32, 0, null).read(reader, undefined, ctx);
                },
                1...MaxIndirectBits => {
                    out.* = .{ .indirect = .{
                        .palette = .{},
                        .data = IndirectData.init(@intCast(bits)),
                    } };
                    try serde.Casted(VarI32, IndirectPaletteLen)
                        .read(reader, &out.indirect.palette.len, ctx);
                    for (out.indirect.palette.slice()) |*item|
                        try serde.Casted(VarI32, Id).read(reader, item, ctx);

                    var read_long_len: u32 = undefined;
                    try serde.Casted(VarI32, u32).read(reader, &read_long_len, ctx);
                    for (out.indirect.data.longSlice()) |*item|
                        try serde.Num(u64, .big).read(reader, item, ctx);
                },
                MaxIndirectBits + 1...MaxDirectBits => {
                    var read_long_len: u32 = undefined;
                    try serde.Casted(VarI32, u32).read(reader, &read_long_len, ctx);
                    out.* = .{ .direct = DirectData.init(@intCast(bits)) };
                    for (out.direct.longSlice()) |*item|
                        try serde.Num(u64, .big).read(reader, item, ctx);
                },
                else => return error.InvalidBits,
            }
        }
        pub fn deinit(self: *UT, _: anytype) void {
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            switch (self) {
                .single => |id| return 1 +
                    VarI32.size(@intCast(id), ctx) + VarI32.size(0, ctx),
                .indirect => |d| {
                    const longs = d.data.constLongSlice();
                    var total =
                        1 + VarI32.size(@intCast(d.palette.len), ctx) +
                        VarI32.size(@intCast(longs.len), ctx);
                    for (d.palette.slice()) |item|
                        total += VarI32.size(@intCast(item), ctx);
                    for (longs) |item|
                        total += serde.Num(u64, .big).size(item, ctx);
                    return total;
                },
                .direct => |d| {
                    const longs = d.constLongSlice();
                    var total = 1 + VarI32.size(@intCast(longs.len), ctx);
                    for (longs) |item| total += serde.Num(u64, .big).size(item, ctx);
                    return total;
                },
            }
        }
    };
}

test "paletted container" {
    const ST = PalettedContainer(.block);
    var cont = ST{ .single = 0 };
    try serde.doTestOnValue(ST, cont, .{});
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
    try serde.doTestOnValue(ST, cont, .{});
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
    try serde.doTestOnValue(ST, cont, .{});
}
