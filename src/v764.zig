const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const Uuid6 = @import("uuid6");

const serde = @import("serde.zig");
const PrefixedArray = serde.PrefixedArray;
const TaggedUnion = serde.TaggedUnion;
const Optional = serde.Optional;
const StringEnum = serde.StringEnum;
const Enum = serde.Enum;
const Remaining = serde.Remaining;

const VarInt = @import("varint.zig").VarInt;
const nbt = @import("nbt.zig");

const generated = @import("mcp-generated");
pub const Block = generated.Block;
pub const BlockState = generated.BlockState;
pub const Biome = generated.Biome;
pub const Dimension = generated.Dimension;
pub const Effect = generated.Effect;

const VarU7 = VarInt(u7); // always a single byte, but its still technically a varint in the protocol i guess
const VarI32 = VarInt(i32);
const VarI64 = VarInt(i64);

pub const ProtocolVersion = 764;
pub const MCVersion = "1.20.2";

/// String serialization type, because the protocol works with codepoint counts, not byte counts
pub fn PString(comptime max_len_opt: ?usize) type {
    return struct {
        pub const UT = []const u8;
        pub const E = VarI32.E || std.unicode.Utf8DecodeError || error{
            TruncatedInput,
            StringTooLarge,
            NegativeLength,
            EndOfStream,
        };

        pub fn characterCount(self: UT) !usize {
            return try std.unicode.utf8CountCodepoints(self);
        }
        pub fn write(writer: anytype, in: UT) !void {
            try VarI32.write(writer, @intCast(try characterCount(in)));
            try writer.writeAll(in);
        }

        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            var len_: i32 = undefined;
            try VarI32.read(reader, &len_, undefined);
            if (len_ < 0) return error.NegativeLength;
            const len: u32 = @intCast(len_);
            if (max_len_opt) |max_len| {
                if (len > max_len) return error.StringTooLarge;
            }
            var data = try std.ArrayList(u8).initCapacity(a, len);
            defer data.deinit();
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const first_byte = try reader.readByte();
                const codepoint_len = try std.unicode.utf8ByteSequenceLength(first_byte);
                try data.ensureUnusedCapacity(codepoint_len);
                data.appendAssumeCapacity(first_byte);
                if (codepoint_len > 0) {
                    var codepoint_buf: [3]u8 = undefined;
                    try reader.readNoEof(codepoint_buf[0 .. codepoint_len - 1]);
                    data.appendSliceAssumeCapacity(codepoint_buf[0 .. codepoint_len - 1]);
                }
            }
            out.* = try data.toOwnedSlice();
        }
        pub fn deinit(self: *UT, alloc: Allocator) void {
            alloc.free(self.*);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            var len = characterCount(self) catch unreachable;
            return VarI32.size(@intCast(len)) + self.len;
        }
    };
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
        @memcpy(buf[ofp.len..], username);
        var uuid: UT = undefined;
        std.crypto.hash.Md5.hash(buf[0 .. ofp.len + username.len], &uuid.bytes, .{});
        uuid.setVersion(3);
        uuid.setVariant(.rfc4122);
        return uuid;
    }
};

pub const ChatString = PString(262144);
pub const Identifier = PString(32767);

pub const MaxNbtDepth = 32;

pub fn Registry(comptime name: []const u8, comptime Entry: type) type {
    return nbt.WithName(name, struct {
        type: nbt.Constant(nbt.String, @constCast(name), serde.strEql),
        value: []struct {
            name: nbt.String,
            id: i32,
            element: Entry,
        },
    });
}

pub const RegistryData = nbt.Named(null, struct {
    trim_material: Registry("minecraft:trim_material", struct {
        asset_name: nbt.String,
        ingredient: nbt.String,
        item_model_index: f32,
        override_armor_materials: ?struct {
            leather: ?nbt.String,
            chainmail: ?nbt.String,
            iron: ?nbt.String,
            gold: ?nbt.String,
            diamond: ?nbt.String,
            turtle: ?nbt.String,
            netherite: ?nbt.String,
        },
        description: nbt.Dynamic(.any, MaxNbtDepth),
    }),
    trim_pattern: Registry("minecraft:trim_pattern", struct {
        asset_id: nbt.String,
        template_item: nbt.String,
        description: nbt.Dynamic(.any, MaxNbtDepth),
        decal: bool,
    }),
    biome: Registry("minecraft:worldgen/biome", struct {
        has_precipitation: bool,
        temperature: f32,
        temperature_modifier: ?nbt.String,
        downfall: f32,
        effects: struct {
            fog_color: i32,
            water_color: i32,
            water_fog_color: i32,
            sky_color: i32,
            foliage_color: ?i32,
            grass_color: ?i32,
            grass_color_modifier: ?nbt.String,
            particle: ?struct {
                options: struct {
                    type: nbt.String,
                    value: ?nbt.Dynamic(.any, MaxNbtDepth),
                },
                probability: f32,
            },
            ambient_sound: ?nbt.Dynamic(.any, MaxNbtDepth),
            mood_sound: ?struct {
                sound: nbt.String,
                tick_delay: i32,
                block_search_extent: i32,
                offset: f64,
            },
            additions_sound: ?struct {
                sound: nbt.String,
                tick_chance: f64,
            },
            music: ?struct {
                sound: nbt.String,
                min_delay: i32,
                max_delay: i32,
                replace_current_music: bool,
            },
        },
    }),
    chat_type: Registry("minecraft:chat_type", struct {
        chat: Decoration,
        narration: Decoration,

        const Decoration = struct {
            translation_key: nbt.String,
            style: ?nbt.Dynamic(.compound, MaxNbtDepth),
            parameters: []nbt.StringEnum(struct {
                pub const sender = "sender";
                pub const target = "target";
                pub const content = "content";
            }),
        };
    }),
    damage_type: Registry("minecraft:damage_type", struct {
        message_id: nbt.String,
        scaling: nbt.StringEnum(struct {
            pub const never = "never";
            pub const when_caused_by_living_non_player =
                "when_caused_by_living_non_player";
            pub const always = "always";
        }),
        exhaustion: f32,
        effects: ?nbt.StringEnum(struct {
            pub const hurt = "hurt";
            pub const thorns = "thorns";
            pub const drowning = "drowning";
            pub const burning = "burning";
            pub const poking = "poking";
            pub const freezing = "freezing";
        }),
        death_message_type: ?nbt.StringEnum(struct {
            pub const default = "default";
            pub const fall_variants = "fall_variants";
            pub const intentional_game_design = "intentional_game_design";
        }),
    }),
    dimension_type: Registry("minecraft:dimension_type", struct {
        fixed_time: ?i64,
        has_skylight: bool,
        has_ceiling: bool,
        ultrawarm: bool,
        natural: bool,
        coordinate_scale: f64,
        bed_works: bool,
        respawn_anchor_works: bool,
        min_y: i32,
        height: i32,
        logical_height: i32,
        infiniburn: nbt.String,
        effects: nbt.StringEnum(struct {
            pub const overworld = "minecraft:overworld";
            pub const nether = "minecraft:the_nether";
            pub const end = "minecraft:the_end";
        }),
        ambient_light: f32,
        piglin_safe: bool,
        has_raids: bool,
        monster_spawn_light_level: nbt.Multiple(union(enum) {
            int: i32,
            compound: struct {
                type: nbt.StringEnum(struct {
                    pub const constant = "minecraft:constant";
                    pub const uniform = "minecraft:uniform";
                    pub const biased_to_bottom = "minecraft:biased_to_bottom";
                    pub const clamped = "minecraft:clamped";
                    pub const weighted_list = "minecraft:weighted_list";
                    pub const clamped_normal = "minecraft:clamped_normal";
                }),
                value: struct {
                    max_inclusive: i32, // TODO: these might only apply to uniform
                    min_inclusive: i32,
                },
            },
        }),
        monster_spawn_block_light_limit: i32,
    }),
});

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

pub const CommandNode = struct {
    pub const NodeType = enum(u2) {
        root = 0,
        literal = 1,
        argument = 2,
    };
    pub const FlagsSpec = serde.Spec(packed struct(u8) {
        node_type: NodeType,
        is_executable: bool,
        has_redirect: bool,
        has_suggestions_type: bool,
        _u: u3 = 0,
    });
    pub const ChildrenSpec = PrefixedArray(VarI32, VarI32, .{});
    pub const NameSpec = PString(32767);
    pub const ParserSpec = TaggedUnion(VarU7, union(ParserKind) {
        pub const ParserKind = enum(u7) {
            bool = 0,
            float = 1,
            double = 2,
            integer = 3,
            long = 4,
            string = 5,
            entity = 6,
            game_profile = 7,
            block_pos = 8,
            column_pos = 9,
            vec3 = 10,
            vec2 = 11,
            block_state = 12,
            block_predicate = 13,
            item_stack = 14,
            item_predicate = 15,
            color = 16,
            component = 17,
            message = 18,
            nbt = 19,
            nbt_tag = 20,
            nbt_path = 21,
            objective = 22,
            objective_criteria = 23,
            operation = 24,
            particle = 25,
            angle = 26,
            rotation = 27,
            scoreboard_slot = 28,
            score_holder = 29,
            swizzle = 30,
            team = 31,
            item_slot = 32,
            resource_location = 33,
            function = 34,
            entity_anchor = 35,
            int_range = 36,
            float_range = 37,
            dimension = 38,
            gamemode = 39,
            time = 40,
            resource_or_tag = 41,
            resource_or_tag_key = 42,
            resource = 43,
            resource_key = 44,
            template_mirror = 45,
            template_rotation = 46,
            heightmap = 47,
            uuid = 48,
        };
        fn BrigadierRange(comptime T: type) type {
            return struct {
                const info = @typeInfo(InnerSpec.UT);
                const max_value =
                    if (info == .Float) math.floatMax(InnerSpec.UT) else math.maxInt(InnerSpec.UT);
                const min_value =
                    if (info == .Float) math.floatMin(InnerSpec.UT) else math.minInt(InnerSpec.UT);
                pub const InnerSpec = serde.Num(T, .big);
                pub const E = InnerSpec.E || error{EndOfStream};

                min: InnerSpec.UT,
                max: InnerSpec.UT,

                pub const UT = @This();
                pub fn write(writer: anytype, in: @This()) !void {
                    try writer.writeByte(
                        (if (in.min != min_value) 0b01 else 0) |
                            (if (in.max != max_value) 0b10 else 0),
                    );
                    if (in.min != min_value) try InnerSpec.write(writer, in.min);
                    if (in.max != max_value) try InnerSpec.write(writer, in.max);
                }
                pub fn read(reader: anytype, out: *@This(), a: Allocator) !void {
                    const b = try reader.readByte();
                    if ((b & 0b01) != 0) {
                        try InnerSpec.read(reader, &out.min, a);
                    } else {
                        out.min = min_value;
                    }
                    if ((b & 0b10) != 0) {
                        try InnerSpec.read(reader, &out.max, a);
                    } else {
                        out.max = max_value;
                    }
                }
                pub fn size(self: @This()) usize {
                    return 1 +
                        (if (self.min != min_value) InnerSpec.size(self.min) else 0) +
                        (if (self.max != max_value) InnerSpec.size(self.max) else 0);
                }
                pub fn deinit(self: *@This(), a: Allocator) void {
                    InnerSpec.deinit(&self.max, a);
                    InnerSpec.deinit(&self.min, a);
                    self.* = undefined;
                }
            };
        }
        bool: void,
        float: BrigadierRange(f32),
        double: BrigadierRange(f64),
        integer: BrigadierRange(i32),
        long: BrigadierRange(i64),
        string: Enum(VarU7, enum(u7) {
            single_word = 0,
            quotable_phrase = 1,
            greedy_phrase = 2,
        }),
        entity: packed struct(u8) {
            only_single_entity: bool,
            only_players: bool,
            _u: u6 = 0,
        },
        game_profile: void,
        block_pos: void,
        column_pos: void,
        vec3: void,
        vec2: void,
        block_state: void,
        block_predicate: void,
        item_stack: void,
        item_predicate: void,
        color: void,
        component: void,
        message: void,
        nbt: void,
        nbt_tag: void,
        nbt_path: void,
        objective: void,
        objective_criteria: void,
        operation: void,
        particle: void,
        angle: void,
        rotation: void,
        scoreboard_slot: void,
        score_holder: packed struct(u8) {
            multiple: bool,
            _u: u7 = 0,
        },
        swizzle: void,
        team: void,
        item_slot: void,
        resource_location: void,
        function: void,
        entity_anchor: void,
        int_range: void,
        float_range: void,
        dimension: void,
        gamemode: void,
        time: struct {
            min: i32,
        },
        resource_or_tag: struct {
            registry: Identifier,
        },
        resource_or_tag_key: struct {
            registry: Identifier,
        },
        resource: struct {
            registry: Identifier,
        },
        resource_key: struct {
            registry: Identifier,
        },
        template_mirror: void,
        template_rotation: void,
        heightmap: void,
        uuid: void,
    });
    pub const SuggestionsSpec = StringEnum(struct {
        pub const ask_server = "minecraft:ask_server";
        pub const all_recipes = "minecraft:all_recipes";
        pub const available_sounds = "minecraft:available_sounds";
        pub const available_biomes = "minecraft:available_biomes";
        pub const summonable_entities = "minecraft:summonable_entities";
    }, Identifier);

    pub const Data = union(NodeType) {
        root: void,
        literal: struct {
            name: NameSpec.UT,
        },
        argument: struct {
            name: NameSpec.UT,
            parser: ParserSpec.UT,
        },
    };

    children: ChildrenSpec.UT,
    data: Data,
    is_executable: bool,
    redirect_node: ?VarI32.UT,
    suggestion: ?SuggestionsSpec.UT,

    pub const E =
        FlagsSpec.E || ChildrenSpec.E || NameSpec.E ||
        ParserSpec.E || SuggestionsSpec.E || VarI32.E;

    pub const UT = @This();
    pub fn write(writer: anytype, in: UT) !void {
        try FlagsSpec.write(writer, .{
            .node_type = in.data,
            .is_executable = in.is_executable,
            .has_redirect = in.redirect_node != null,
            .has_suggestions_type = in.suggestion != null,
        });
        try ChildrenSpec.write(writer, in.children);
        if (in.redirect_node) |redirect_node|
            try VarI32.write(writer, redirect_node);
        switch (in.data) {
            .argument => |d| {
                try NameSpec.write(writer, d.name);
                try ParserSpec.write(writer, d.parser);
            },
            .literal => |d| {
                try NameSpec.write(writer, d.name);
            },
            else => {},
        }
        if (in.suggestion) |suggestion|
            try SuggestionsSpec.write(writer, suggestion);
    }
    pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
        var flags: FlagsSpec.UT = undefined;
        try FlagsSpec.read(reader, &flags, a);
        out.is_executable = flags.is_executable;
        try ChildrenSpec.read(reader, &out.children, a);
        if (flags.has_redirect) {
            out.redirect_node = @as(VarI32.UT, undefined);
            try VarI32.read(reader, &out.redirect_node.?, a);
        } else {
            out.redirect_node = null;
        }
        if (flags.node_type == .literal) {
            out.data = .{ .literal = undefined };
            try NameSpec.read(reader, &out.data.literal.name, a);
        } else if (flags.node_type == .argument) {
            out.data = .{ .argument = undefined };
            try NameSpec.read(reader, &out.data.argument.name, a);
            try ParserSpec.read(reader, &out.data.argument.parser, a);
        }
        if (flags.has_suggestions_type) {
            out.suggestion = @as(SuggestionsSpec.UT, undefined);
            try SuggestionsSpec.read(reader, &out.suggestion.?, a);
        } else {
            out.suggestion = null;
        }
    }
    pub fn size(self: UT) usize {
        return 1 + ChildrenSpec.size(self.children) +
            (if (self.redirect_node) |n| VarI32.size(n) else 0) + switch (self.data) {
            .argument => |d| NameSpec.size(d.name) + ParserSpec.size(d.parser),
            .literal => |d| NameSpec.size(d.name),
            else => 0,
        } +
            (if (self.suggestion) |suggestion| SuggestionsSpec.size(suggestion) else 0);
    }
    pub fn deinit(self: *UT, a: Allocator) void {
        if (self.suggestion) |*suggestion|
            SuggestionsSpec.deinit(suggestion, a);
        switch (self.data) {
            .argument => |*d| {
                ParserSpec.deinit(&d.parser, a);
                NameSpec.deinit(&d.name, a);
            },
            .literal => |*d| {
                NameSpec.deinit(&d.name, a);
            },
            else => {},
        }
        ChildrenSpec.deinit(&self.children, a);
        self.* = undefined;
    }
};

pub const Slot = Optional(struct {
    item_id: VarI32,
    item_count: i8,
    data: serde.ConstantOptional(
        nbt.Named(null, nbt.Dynamic(.any, MaxNbtDepth)),
        .end,
        serde.DeepEql(nbt.DynamicValue),
    ),
});

test "protocol slot" {
    // https://wiki.vg/Slot_Data
    try serde.doTest(Slot, &.{0x00}, null);
    try serde.doTest(Slot, &.{ 0x01, 0x01, 0x01, 0x00 }, .{
        .item_id = 1,
        .item_count = 1,
        .data = null,
    });
    try serde.doTest(Slot, &.{ 0x01, 0x01, 0x01, 0x03, 0x12, 0x34, 0x56, 0x78 }, .{
        .item_id = 1,
        .item_count = 1,
        .data = .{ .int = @bitCast(@as(u32, 0x12345678)) },
    });
}

// TODO: make a custom type for this so it is more easily usable
pub const BitSet = PrefixedArray(VarI32, i64, .{});

pub fn PlusOne(comptime T: type) type {
    return serde.Mapped(T, struct {
        pub const O = serde.Spec(T).UT;
        pub fn from(in_: O) O {
            return if (in_) |in| in + 1 else null;
        }
        pub fn to(in_: *O, out: *O, _: Allocator) !void {
            out.* = if (in_.*) |in| in - 1 else null;
        }
    });
}

pub const ParticleId = enum(i32) {
    ambient_entity_effect = 0,
    angry_villager = 1,
    block = 2,
    block_marker = 3,
    bubble = 4,
    cloud = 5,
    crit = 6,
    damage_indicator = 7,
    dragon_breath = 8,
    dripping_lava = 9,
    falling_lava = 10,
    landing_lava = 11,
    dripping_water = 12,
    falling_water = 13,
    dust = 14,
    dust_color_transition = 15,
    effect = 16,
    elder_guardian = 17,
    enchanted_hit = 18,
    enchant = 19,
    end_rod = 20,
    entity_effect = 21,
    explosion_emitter = 22,
    explosion = 23,
    sonic_boom = 24,
    falling_dust = 25,
    firework = 26,
    fishing = 27,
    flame = 28,
    cherry_leaves = 29,
    sculk_soul = 30,
    sculk_charge = 31,
    sculk_charge_pop = 32,
    soul_fire_flame = 33,
    soul = 34,
    flash = 35,
    happy_villager = 36,
    composter = 37,
    heart = 38,
    instant_effect = 39,
    item = 40,
    vibration = 41,
    item_slime = 42,
    item_snowball = 43,
    large_smoke = 44,
    lava = 45,
    mycelium = 46,
    note = 47,
    poof = 48,
    portal = 49,
    rain = 50,
    smoke = 51,
    sneeze = 52,
    spit = 53,
    squid_ink = 54,
    sweep_attack = 55,
    totem_of_undying = 56,
    underwater = 57,
    splash = 58,
    witch = 59,
    bubble_pop = 60,
    current_down = 61,
    bubble_column_up = 62,
    nautilus = 63,
    dolphin = 64,
    campfire_cosy_smoke = 65,
    campfire_signal_smoke = 66,
    dripping_honey = 67,
    falling_honey = 68,
    landing_honey = 69,
    falling_nectar = 70,
    falling_spore_blossom = 71,
    ash = 72,
    crimson_spore = 73,
    warped_spore = 74,
    spore_blossom_air = 75,
    dripping_obsidian_tear = 76,
    falling_obsidian_tear = 77,
    landing_obsidian_tear = 78,
    reverse_portal = 79,
    white_ash = 80,
    small_flame = 81,
    snowflake = 82,
    dripping_dripstone_lava = 83,
    falling_dripstone_lava = 84,
    dripping_dripstone_water = 85,
    falling_dripstone_water = 86,
    glow_squid_ink = 87,
    glow = 88,
    wax_on = 89,
    wax_off = 90,
    electric_spark = 91,
    scrape = 92,
    shriek = 93,
    egg_crack = 94,
};
pub const Particle = serde.Union(union(ParticleId) {
    ambient_entity_effect: void,
    angry_villager: void,
    block: struct {
        block_state: VarI32,
    },
    block_marker: struct {
        block_state: VarI32,
    },
    bubble: void,
    cloud: void,
    crit: void,
    damage_indicator: void,
    dragon_breath: void,
    dripping_lava: void,
    falling_lava: void,
    landing_lava: void,
    dripping_water: void,
    falling_water: void,
    dust: struct {
        r: f32,
        g: f32,
        b: f32,
        scale: f32,
    },
    dust_color_transition: struct {
        from_r: f32,
        from_g: f32,
        from_b: f32,
        scale: f32,
        to_r: f32,
        to_g: f32,
        to_b: f32,
    },
    effect: void,
    elder_guardian: void,
    enchanted_hit: void,
    enchant: void,
    end_rod: void,
    entity_effect: void,
    explosion_emitter: void,
    explosion: void,
    sonic_boom: void,
    falling_dust: struct {
        block_state: VarI32,
    },
    firework: void,
    fishing: void,
    flame: void,
    cherry_leaves: void,
    sculk_soul: void,
    sculk_charge: struct {
        roll: f32,
    },
    sculk_charge_pop: void,
    soul_fire_flame: void,
    soul: void,
    flash: void,
    happy_villager: void,
    composter: void,
    heart: void,
    instant_effect: void,
    item: Slot,
    vibration: struct {
        // no idea if there are other possible values for source type
        const SourceSpec = serde.MappedEnum(struct {
            pub const block = "minecraft:block";
            pub const entity = "minecraft:entity";
            pub const other = null;
        }, Identifier, (struct {
            pub fn f(a: ?[]const u8, b: []const u8) bool {
                return if (a == null) true else mem.eql(u8, a.?, b);
            }
        }).f);
        source: serde.Pass(SourceSpec, serde.Union(union(SourceSpec.UT) {
            block: Position,
            entity: struct {
                id: VarI32,
                eye_height: f32,
            },
            other: void,
        })),
        ticks: VarI32,
    },
    item_slime: void,
    item_snowball: void,
    large_smoke: void,
    lava: void,
    mycelium: void,
    note: void,
    poof: void,
    portal: void,
    rain: void,
    smoke: void,
    sneeze: void,
    spit: void,
    squid_ink: void,
    sweep_attack: void,
    totem_of_undying: void,
    underwater: void,
    splash: void,
    witch: void,
    bubble_pop: void,
    current_down: void,
    bubble_column_up: void,
    nautilus: void,
    dolphin: void,
    campfire_cosy_smoke: void,
    campfire_signal_smoke: void,
    dripping_honey: void,
    falling_honey: void,
    landing_honey: void,
    falling_nectar: void,
    falling_spore_blossom: void,
    ash: void,
    crimson_spore: void,
    warped_spore: void,
    spore_blossom_air: void,
    dripping_obsidian_tear: void,
    falling_obsidian_tear: void,
    landing_obsidian_tear: void,
    reverse_portal: void,
    white_ash: void,
    small_flame: void,
    snowflake: void,
    dripping_dripstone_lava: void,
    falling_dripstone_lava: void,
    dripping_dripstone_water: void,
    falling_dripstone_water: void,
    glow_squid_ink: void,
    glow: void,
    wax_on: void,
    wax_off: void,
    electric_spark: void,
    scrape: void,
    shriek: struct {
        delay: VarI32,
    },
    egg_crack: void,
});
pub const WorldEventId = enum(i32) {
    dispenser_dispenses = 1000,
    dispenser_fails = 1001,
    dispenser_shoots = 1002,
    ender_eye_launched = 1003,
    firework_shot = 1004,
    iron_door_opened = 1005,
    wooden_door_opened = 1006,
    wooden_trapdoor_opened = 1007,
    fence_gate_opened = 1008,
    fire_extinguished = 1009,
    play_record = 1010,
    iron_door_closed = 1011,
    wooden_door_closed = 1012,
    wooden_trapdoor_closed = 1013,
    fence_gate_closed = 1014,
    ghast_warns = 1015,
    ghast_shoots = 1016,
    enderdragon_shoots = 1017,
    blaze_shoots = 1018,
    zombie_attacks_wooden_door = 1019,
    zombie_attacks_iron_door = 1020,
    zombie_breaks_wooden_door = 1021,
    wither_breaks_block = 1022,
    wither_spawned = 1023,
    wither_shoots = 1024,
    bat_takes_off = 1025,
    zombie_inflicts = 1026,
    zombie_villager_converted = 1027,
    ender_dragon_death = 1028,
    anvil_destroyed = 1029,
    anvil_used = 1030,
    anvil_landed = 1031,
    portal_travel = 1032,
    chorus_flower_grown = 1033,
    chorus_flower_died = 1034,
    brewing_stand_brewed = 1035,
    iron_trapdoor_opened = 1036,
    iron_trapdoor_closed = 1037,
    end_portal_created_in_overworld = 1038,
    phantom_bites = 1039,
    zombie_converts_to_drowned = 1040,
    husk_converts_to_zombie_by_drowning = 1041,
    grindstone_used = 1042,
    book_page_turned = 1043,

    composter_composts = 1500,
    lava_converts_block = 1501,
    redstone_torch_burns_out = 1502,
    ender_eye_placed = 1503,
    spawn_smoke_particles = 2000,
    block_break = 2001,
    splash_potion_break = 2002,
    eye_of_ender_break = 2003,
    mob_spawn_particles = 2004,
    bonemeal_particles = 2005,
    enderdragon_breath = 2006,
    instant_splash_potion_break = 2007,
    enderdragon_destroys_block = 2008,
    wet_sponge_vaporizes = 2009,
    end_gateway_spawn = 3000,
    enderdragon_growl = 3001,
    electric_spark = 3002,
    copper_apply_wax = 3003,
    copper_remove_wax = 3004,
    copper_scrape_oxidation = 3005,
};
pub const WorldEvent = serde.Union(union(WorldEventId) {
    const I320 = serde.Constant(i32, 0, serde.AnyEql(i32));
    dispenser_dispenses: I320,
    dispenser_fails: I320,
    dispenser_shoots: I320,
    ender_eye_launched: I320,
    firework_shot: I320,
    iron_door_opened: I320,
    wooden_door_opened: I320,
    wooden_trapdoor_opened: I320,
    fence_gate_opened: I320,
    fire_extinguished: I320,
    play_record: i32,
    iron_door_closed: I320,
    wooden_door_closed: I320,
    wooden_trapdoor_closed: I320,
    fence_gate_closed: I320,
    ghast_warns: I320,
    ghast_shoots: I320,
    enderdragon_shoots: I320,
    blaze_shoots: I320,
    zombie_attacks_wooden_door: I320,
    zombie_attacks_iron_door: I320,
    zombie_breaks_wooden_door: I320,
    wither_breaks_block: I320,
    wither_spawned: I320,
    wither_shoots: I320,
    bat_takes_off: I320,
    zombie_inflicts: I320,
    zombie_villager_converted: I320,
    ender_dragon_death: I320,
    anvil_destroyed: I320,
    anvil_used: I320,
    anvil_landed: I320,
    portal_travel: I320,
    chorus_flower_grown: I320,
    chorus_flower_died: I320,
    brewing_stand_brewed: I320,
    iron_trapdoor_opened: I320,
    iron_trapdoor_closed: I320,
    end_portal_created_in_overworld: I320,
    phantom_bites: I320,
    zombie_converts_to_drowned: I320,
    husk_converts_to_zombie_by_drowning: I320,
    grindstone_used: I320,
    book_page_turned: I320,

    composter_composts: I320,
    lava_converts_block: I320,
    redstone_torch_burns_out: I320,
    ender_eye_placed: I320,
    spawn_smoke_particles: enum(i32) {
        down = 0,
        up = 1,
        north = 2,
        south = 3,
        west = 4,
        east = 5,
    },
    block_break: i32,
    splash_potion_break: packed struct(i32) { b: u8, g: u8, r: u8, _u: u8 = 0 },
    eye_of_ender_break: I320,
    mob_spawn_particles: I320,
    bonemeal_particles: serde.ConstantOptional(i32, 0, null),
    enderdragon_breath: I320,
    instant_splash_potion_break: packed struct(i32) { b: u8, g: u8, r: u8, _u: u8 = 0 },
    enderdragon_destroys_block: I320,
    wet_sponge_vaporizes: I320,
    end_gateway_spawn: I320,
    enderdragon_growl: I320,
    electric_spark: I320,
    copper_apply_wax: I320,
    copper_remove_wax: I320,
    copper_scrape_oxidation: I320,
});
pub const BlockEntity = serde.Struct(struct {
    xz: packed struct(u8) {
        z: u4,
        x: u4,
    },
    y: i16,
    type: VarI32,
    data: nbt.Named(null, nbt.Dynamic(.any, MaxNbtDepth)),
});
pub const LightLevels = serde.Struct(struct {
    sky_light_mask: BitSet,
    block_light_mask: BitSet,
    empty_sky_light_mask: BitSet,
    empty_block_light_mask: BitSet,
    sky_lights: PrefixedArray(VarI32, struct {
        len: serde.Constant(VarI32, 2048, null),
        data: [2048]u8,
    }, .{}),
    block_lights: PrefixedArray(VarI32, struct {
        len: serde.Constant(VarI32, 2048, null),
        data: [2048]u8,
    }, .{}),
});

pub const HeightMap = struct {
    pub const len = math.divCeil(usize, 256, @divTrunc(64, 9)) catch unreachable;
    pub const ListSpec = serde.Struct(struct {
        _len: serde.Constant(serde.Num(i32, .big), @intCast(len), null),
        data: serde.Array([len]u64),
    });

    inner: ListSpec.UT,

    pub const UT = @This();
    pub const E = ListSpec.E;

    pub fn write(writer: anytype, in: UT) !void {
        try ListSpec.write(writer, in.inner);
    }
    pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
        try ListSpec.read(reader, &out.inner, a);
    }
    pub fn size(self: UT) usize {
        return ListSpec.size(self);
    }
    pub fn deinit(self: *UT, a: Allocator) void {
        ListSpec.deinit(&self.inner, a);
        self.* = undefined;
    }

    pub fn initAll(value: u9) Self {
        var part: u64 = 0;
        for (0..7) |_| {
            part |= @as(u64, value);
            part <<= 9;
        }
        part <<= 1;
        var self: Self = undefined;
        for (0..36) |i| self.inner.data[i] = part;
        self.inner.data[36] = (part << (9 * 5)) >> (9 * 5);
        return self;
    }

    const Self = @This();
    pub fn set(self: *Self, x: u4, z: u4, value: u9) void {
        return self.setIndex((@as(u8, z) << 4) + x, value);
    }
    pub fn get(self: *Self, x: u4, z: u4) u9 {
        return self.getIndex((@as(u8, z) << 4) + x);
    }

    const mask_ = ~(~@as(u64, 0) << 9);
    pub fn setIndex(self: *Self, index: u8, value: u9) void {
        const shift = 9 * @as(std.math.Log2Int(u64), @intCast(index % 7)) + 1;
        const mask = ~(mask_ << shift);
        const long_ind = index / 7;
        self.inner.data[long_ind] &= mask;
        self.inner.data[long_ind] |= @as(u64, value) << shift;
    }
    pub fn getIndex(self: *Self, index: u8) u9 {
        const shift = 9 * @as(std.math.Log2Int(u64), @intCast(index % 7)) + 1;
        const long_ind = index / 7;
        return @truncate(self.inner.data[long_ind] >> shift);
    }
};
test "heightmap" {
    var m = HeightMap.initAll(1);
    for (0..256) |i| m.setIndex(@intCast(i), @intCast(i));
    for (0..256) |i| try testing.expectEqual(@as(u9, @intCast(i)), m.getIndex(@intCast(i)));
}

pub const ChunkSection = serde.Struct(struct {
    block_count: i16,
    blocks: PalettedContainer(.block),
    biomes: PalettedContainer(.biome),
});

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
            .block => u4,
            .biome => u2,
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
        pub const MaxIndirectLongCount = math.divCeil(
            usize,
            Count,
            @divTrunc(64, @typeInfo(IndirectId).Int.bits),
        ) catch unreachable;
        pub const MaxIndirectPaletteLength = math.maxInt(IndirectId) + 1;
        pub const IndirectPaletteLen =
            std.math.IntFittingRange(0, MaxIndirectPaletteLength);

        pub inline fn axisToIndex(x: Axis, z: Axis, y: Axis) Index {
            const one_shift: comptime_int = @intCast(@typeInfo(Axis).Int.bits);
            return (@as(Index, y) << (one_shift * 2)) |
                (@as(Index, z) << one_shift) |
                @as(Index, x);
        }
        pub fn PackedArray(comptime max_bits: comptime_int) type {
            return struct {
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
                    return @intCast(index / (64 / bits));
                }
                pub inline fn lowIndex(bits: Bits, index: Index) ShiftInt {
                    return @intCast(index % (64 / bits));
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
                    return self.getIntArray(self.bits, index);
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

        pub const IndirectData = PackedArray(MaxIndirectBits);
        pub const PaletteData = std.BoundedArray(Id, MaxIndirectPaletteLength);
        pub const DirectData = PackedArray(16);

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
                    .data = IndirectData.init(1),
                } },
                .indirect => |d| {
                    var direct = DirectData.init(IdBits);
                    for (0..Count) |i| {
                        direct.set(@intCast(i), d.palette[d.data.get(@intCast(i))]);
                    }
                    self.* = .{ .direct = direct };
                },
                else => {},
            }
        }
        pub fn set(self: *Self, x: Axis, z: Axis, y: Axis, value: Id) void {
            const index = axisToIndex(x, z, y);
            switch (self.*) {
                .single => |id| if (value != id) {
                    self.upgrade(); // upgrade to indirect
                    const palette_id = self.indirect.palette.len;
                    self.indirect.palette.appendAssumeCapacity(id);
                    self.indirect.data.set(index, @intCast(palette_id));
                },
                .indirect => |*d| {
                    const palette_id: IndirectPaletteLen =
                        for (self.indirect.palette.slice(), 0..) |id, i|
                        if (id == value)
                            break @intCast(i)
                        else
                            self.indirect.palette.len;
                    if (palette_id == self.indirect.palette.len) {
                        self.indirect.palette.append(value) catch {
                            self.upgrade(); // upgrade to direct
                            self.direct.set(index, value);
                            return;
                        };
                        if (self.palette_len > (1 << @as(IndirectPaletteLen, d.bits)))
                            d.changeBits(d.bits + 1);
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
        pub fn get(self: *Self, x: Axis, z: Axis, y: Axis) Id {
            const index = axisToIndex(x, z, y);
            return switch (self.*) {
                .single => |id| id,
                .indirect => |d| d.palette.get(d.data.get(index)),
                .direct => |d| d.get(index),
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
                    const longs = d.data.longSlice();
                    try VarI32.write(writer, @intCast(longs.len));
                    for (longs) |item| try serde.Num(u64, .big).write(writer, item);
                },
                .direct => |d| {
                    try writer.writeByte(d.bits);
                    const longs = d.longSlice();
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
                .single => |id| 1 + VarI32.size(@intCast(id)) + VarI32.size(0),
                .indirect => |d| {
                    const longs = d.data.longSlice();
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
                    const longs = d.longSlice();
                    var total = 1 + VarI32.size(@intCast(longs.len));
                    for (longs) |item| total += serde.Num(u64, .big).size(item);
                    return total;
                },
            }
        }
    };
}

pub const DimensionSpec = StringEnum(struct {
    pub const overworld = "minecraft:overworld";
    pub const nether = "minecraft:the_nether";
    pub const end = "minecraft:the_end";
}, Identifier);

pub const RespawnSpec = serde.Struct(struct {
    dimension_type: Identifier,
    dimension_name: DimensionSpec,
    hashed_seed: u64,
    gamemode: enum(u8) {
        survival = 0,
        creative = 1,
        adventure = 2,
        spectator = 3,
    },
    previous_gamemode: serde.ConstantOptional(enum(u8) {
        survival = 0,
        creative = 1,
        adventure = 2,
        spectator = 3,
        none = @as(u8, @bitCast(@as(i8, -1))),
    }, .none, null),
    is_debug: bool,
    is_flat: bool,
    death_location: ?struct {
        dimension: DimensionSpec,
        location: Position,
    },
    portal_cooldown: VarI32,
});

pub const VillagerLevel = serde.Enum(VarU7, enum(u7) {
    novice = 1,
    apprentice = 2,
    journeyman = 3,
    expert = 4,
    master = 5,
});
pub const VillagerType = serde.Enum(VarU7, enum(u7) {
    desert = 0,
    jungle = 1,
    plains = 2,
    savanna = 3,
    snow = 4,
    swamp = 5,
    taiga = 6,
});
pub const VillagerProfession = serde.Enum(VarU7, enum(u7) {
    none = 0,
    armorer = 1,
    butcher = 2,
    cartographer = 3,
    cleric = 4,
    farmer = 5,
    fisherman = 6,
    fletcher = 7,
    leatherworker = 8,
    librarian = 9,
    mason = 10,
    nitwit = 11,
    shepherd = 12,
    toolsmith = 13,
    weaponsmith = 14,
});

pub const SoundCategory = serde.Enum(VarU7, enum(u7) {
    master = 0,
    music,
    record,
    weather,
    block,
    hostile,
    neutral,
    player,
    ambient,
    voice,
});

pub const AdvancementDisplay = serde.Struct(struct {
    title: ChatString,
    description: ChatString,
    icon: Slot,
    frame_type: serde.Enum(VarU7, enum(u7) { task = 0, challenge = 1, goal = 2 }),
    flags: struct {
        pub const FlagsSpec = serde.Spec(packed struct(u8) {
            has_background_texture: bool,
            show_toast: bool,
            hidden: bool,
            _u: u5 = 0,
        });

        show_toast: bool,
        hidden: bool,
        background_texture: ?Identifier.UT,

        pub const UT = @This();
        pub const E = Identifier.E || FlagsSpec.E;
        pub fn write(writer: anytype, in: UT) !void {
            try FlagsSpec.write(writer, .{
                .has_background_texture = in.background_texture != null,
                .show_toast = in.show_toast,
                .hidden = in.hidden,
            });
            if (in.background_texture) |v| try Identifier.write(writer, v);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            var flags: FlagsSpec.UT = undefined;
            try FlagsSpec.read(reader, &flags, undefined);
            out.show_toast = flags.show_toast;
            out.hidden = flags.hidden;
            if (flags.has_background_texture) {
                out.background_texture = @as(Identifier.UT, undefined);
                try Identifier.read(reader, &out.background_texture.?, a);
            } else {
                out.background_texture = null;
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            if (self.background_texture) |*v| Identifier.deinit(v, a);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            return 1 + if (self.background_texture) |v| Identifier.size(v) else 0;
        }
    },
    x_coord: f32,
    y_coord: f32,
});

pub const Advancement = serde.Struct(struct {
    parent: ?Identifier,
    display: ?AdvancementDisplay,
    requirements: PrefixedArray(
        VarI32,
        PrefixedArray(VarI32, PString(32767), .{}),
        .{},
    ),
    sends_telemetry_data: bool,
});
pub const Ingredient = PrefixedArray(VarI32, Slot, .{});
pub const RecipeType = serde.StringEnum(struct {
    pub const crafting_shapeless = "minecraft:crafting_shapeless";
    pub const crafting_shaped = "minecraft:crafting_shaped";
    pub const crafting_special_armordye = "minecraft:crafting_special_armordye";
    pub const crafting_special_bookcloning = "minecraft:crafting_special_bookcloning";
    pub const crafting_special_mapcloning = "minecraft:crafting_special_mapcloning";
    pub const crafting_special_mapextending = "minecraft:crafting_special_mapextending";
    pub const crafting_special_firework_rocket = "minecraft:crafting_special_firework_rocket";
    pub const crafting_special_firework_star = "minecraft:crafting_special_firework_star";
    pub const crafting_special_firework_star_fade = "minecraft:crafting_special_firework_star_fade";
    pub const crafting_special_repairitem = "minecraft:crafting_special_repairitem";
    pub const crafting_special_tippedarrow = "minecraft:crafting_special_tippedarrow";
    pub const crafting_special_bannerduplicate = "minecraft:crafting_special_bannerduplicate";
    pub const crafting_special_shielddecoration = "minecraft:crafting_special_shielddecoration";
    pub const crafting_special_shulkerboxcoloring = "minecraft:crafting_special_shulkerboxcoloring";
    pub const crafting_special_suspiciousstew = "minecraft:crafting_special_suspiciousstew";
    pub const crafting_decorated_pot = "minecraft:crafting_decorated_pot";
    pub const smelting = "minecraft:smelting";
    pub const blasting = "minecraft:blasting";
    pub const smoking = "minecraft:smoking";
    pub const campfire_cooking = "minecraft:campfire_cooking";
    pub const stonecutting = "minecraft:stonecutting";
    pub const smithing_transform = "minecraft:smithing_transform";
    pub const smithing_trim = "minecraft:smithing_trim";
}, Identifier);
pub const RecipeCategory = serde.Enum(VarU7, enum(u7) {
    building = 0,
    redstone = 1,
    equipment = 2,
    misc = 3,
});

pub const Tags = PrefixedArray(VarI32, struct {
    tag_type: StringEnum(struct {
        // see registries.json
        pub const block = "minecraft:block";
        pub const item = "minecraft:item";
        pub const fluid = "minecraft:fluid";
        pub const entity_type = "minecraft:entity_type";
        pub const game_event = "minecraft:game_event";
        pub const point_of_interest_type = "minecraft:point_of_interest_type";
        pub const painting_variant = "minecraft:painting_variant";
        pub const cat_variant = "minecraft:cat_variant";
        pub const frog_variant = "minecraft:frog_variant";
        pub const activity = "minecraft:activity";
        pub const attribute = "minecraft:attribute";
        pub const banner_pattern = "minecraft:banner_pattern";
        pub const block_entity_type = "minecraft:block_entity_type";
        pub const block_predicate_type = "minecraft:block_predicate_type";
        pub const chunk_status = "minecraft:chunk_status";
        pub const command_argument_type = "minecraft:command_argument_type";
        pub const creative_mode_tab = "minecraft:creative_mode_tab";
        pub const custom_stat = "minecraft:custom_stat";
        pub const decorated_pot_patterns = "minecraft:decorated_pot_patterns";
        pub const enchantment = "minecraft:enchantment";
        pub const float_provider_type = "minecraft:float_provider_type";
        pub const height_provider_type = "minecraft:height_provider_type";
        pub const instrument = "minecraft:instrument";
        pub const int_provider_type = "minecraft:int_provider_type";
        pub const loot_condition_type = "minecraft:loot_condition_type";
        pub const loot_function_type = "minecraft:loot_function_type";
        pub const loot_nbt_provider_type = "minecraft:loot_nbt_provider_type";
        pub const loot_number_provider_type = "minecraft:loot_number_provider_type";
        pub const loot_pool_entry_type = "minecraft:loot_pool_entry_type";
        pub const loot_score_entry_type = "minecraft:loot_score_entry_type";
        pub const memory_module_type = "minecraft:memory_module_type";
        pub const menu = "minecraft:menu";
        pub const mob_effect = "minecraft:mob_effect";
    }, Identifier),
    tags: PrefixedArray(VarI32, struct {
        tag_name: Identifier,
        entries: PrefixedArray(VarI32, VarI32, .{}),
    }, .{}),
}, .{});

pub const Difficulty = enum(u8) {
    peaceful = 0,
    easy = 1,
    normal = 2,
    hard = 3,
};

pub const PublicKey = serde.Struct(struct {
    expiry_time: i64,
    encoded: PrefixedArray(VarI32, u8, .{ .max = 512 }),
    signature: PrefixedArray(VarI32, u8, .{ .max = 4096 }),
});

pub const ClientInformation = serde.Struct(struct {
    locale: PString(16),
    view_distance: u8,
    chat_mode: Enum(VarU7, enum(u7) { full = 0, system = 1, none = 2 }),
    chat_colors: bool,
    displayed_skin_parts: packed struct(u8) {
        cape: bool,
        jacket: bool,
        left_sleeve: bool,
        right_sleeve: bool,
        left_pant: bool,
        right_pant: bool,
        hat: bool,
        _u: u1 = 0,
    },
    main_hand: Hand,
    enable_text_filtering: bool,
    allow_server_listings: bool,
});

// TODO: I sure hope that these values i took from registries.json are actually for this...
pub const PotionId = Enum(VarU7, enum(u7) {
    empty = 0,
    water = 1,
    mundane = 2,
    thick = 3,
    awkward = 4,
    night_vision = 5,
    long_night_vision = 6,
    invisibility = 7,
    long_invisibility = 8,
    leaping = 9,
    long_leaping = 10,
    strong_leaping = 11,
    fire_resistance = 12,
    long_fire_resistance = 13,
    swiftness = 14,
    long_swiftness = 15,
    strong_siftness = 16,
    slowness = 17,
    long_slowness = 18,
    strong_slowness = 19,
    turtle_master = 20,
    long_turtle_master = 21,
    strong_turtle_master = 22,
    water_breathing = 23,
    long_water_breathing = 24,
    healing = 25,
    strong_healing = 26,
    harming = 27,
    strong_harming = 28,
    poison = 29,
    long_poison = 30,
    strong_poison = 31,
    regeneration = 32,
    long_regeneration = 33,
    strong_regeneration = 34,
    strength = 35,
    long_strength = 36,
    strong_strength = 37,
    weakness = 38,
    long_weakness = 39,
    luck = 40,
    slow_falling = 41,
    long_slow_falling = 42,
});

pub const Hand = Enum(VarU7, enum(u7) { left = 0, right = 1 });

pub const PlayerAbilitiesFlags = serde.Packed(packed struct(u8) {
    invulnerable: bool,
    flying: bool,
    allow_flying: bool,
    creative_mode: bool,
    _u: u4 = 0,
}, .big);

pub const H = struct {
    pub const SB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            handshake = 0x00,
            legacy,
        };

        handshake: struct {
            protocol_version: VarI32,
            server_address: PString(255),
            server_port: u16,
            next_state: Enum(VarI32, enum(i32) { status = 1, login = 2 }),
        },
        legacy: void,
    });
};

pub const S = struct {
    pub const SB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            status_request = 0x00,
            ping_request = 0x01,
        };

        status_request: void,
        ping_request: i64,
    });
    pub const CB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            status_response = 0x00,
            ping_response = 0x01,
        };

        status_response: PString(32767),
        ping_response: i64,
    });
};

pub const L = struct {
    pub const SB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            login_start = 0x00,
            encryption_response = 0x01,
            login_plugin_response = 0x02,
            login_acknowledged = 0x03,
        };
        login_start: struct {
            name: PString(16),
            uuid: Uuid,
        },
        encryption_response: struct {
            shared_secret: PrefixedArray(VarI32, u8, .{ .max = 1024 }), // what is actual max here?
            verify_token: PrefixedArray(VarI32, u8, .{ .max = 1024 }),
        },
        login_plugin_response: struct {
            message_id: VarI32,
            data: ?Remaining(u8, .{ .max = 1048576 }),
        },
        login_acknowledged: void,
    });
    pub const CB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            disconnect = 0x00,
            encryption_request = 0x01,
            login_success = 0x02,
            set_compression = 0x03,
            login_plugin_request = 0x04,
        };
        disconnect: ChatString,
        encryption_request: struct {
            server_id: PString(20),
            public_key: PrefixedArray(VarI32, u8, .{ .max = 1024 }), // what is actual max here?
            verify_token: PrefixedArray(VarI32, u8, .{ .max = 1024 }),
        },
        login_success: struct {
            uuid: Uuid,
            username: PString(16),
            properties: PrefixedArray(VarI32, struct {
                name: PString(32767),
                value: PString(32767),
                signature: ?PString(32767), // TODO: is this actually a codepoint string?
            }, .{}), // TODO max
        },
        set_compression: VarI32,
        login_plugin_request: struct {
            message_id: VarI32,
            channel: Identifier,
        },
    });
};

pub const C = struct {
    pub const SB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            client_information = 0x00,
            plugin_message = 0x01,
            finish_configuration = 0x02,
            keep_alive = 0x03,
            pong = 0x04,
            resource_pack_response = 0x05,
        };
        client_information: ClientInformation,
        plugin_message: struct {
            channel: Identifier,
            data: Remaining(u8, .{ .max = 32767 }),
        },
        finish_configuration: void,
        keep_alive: i64,
        pong: i32,
        resource_pack_response: Enum(VarU7, enum(u7) {
            succeeeded = 0,
            declined = 1,
            failed = 2,
            accepted = 4,
        }),
    });
    pub const CB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            plugin_message = 0x00,
            disconnect = 0x01,
            finish_configuration = 0x02,
            keep_alive = 0x03,
            ping = 0x04,
            registry_data = 0x05,
            resource_pack = 0x06,
            feature_flags = 0x07,
            update_tags = 0x08,
        };
        plugin_message: struct {
            channel: Identifier,
            data: Remaining(u8, .{ .max = 1048576 }),
        },
        disconnect: ChatString,
        finish_configuration: void,
        keep_alive: i64,
        ping: i32,
        //registry_data: RegistryData,
        registry_data: nbt.Named(null, nbt.Dynamic(.any, MaxNbtDepth)),
        resource_pack: struct {
            url: PString(32767),
            hash: PString(40),
            forced: bool,
            prompt_message: ?ChatString,
        },
        feature_flags: PrefixedArray(VarI32, StringEnum(struct {
            pub const vanilla = "minecraft:vanilla";
            pub const bundle = "minecraft:bundle";
            pub const trade_rebalance = "minecraft:trade_rebalance";
        }, Identifier), .{}), // max?
        update_tags: Tags,
    });
};

pub const P = struct {
    pub const CB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            bundle_delimeter = 0x00,
            spawn_entity = 0x01,
            spawn_experience_orb = 0x02,
            entity_animation = 0x03,
            award_statistics = 0x04,
            acknowledge_block_change = 0x05,
            set_block_destroy_stage = 0x06,
            block_entity_data = 0x07,
            block_action = 0x08,
            block_update = 0x09,
            boss_bar = 0x0A,
            change_difficulty = 0x0B,
            chunk_batch_finished = 0x0C,
            chunk_batch_start = 0x0D,
            chunk_biomes = 0x0E,
            clear_titles = 0x0F,
            command_suggestions_response = 0x10,
            commands = 0x11,
            close_container = 0x12,
            set_container_content = 0x13,
            set_container_property = 0x14,
            set_container_slot = 0x15,
            set_cooldown = 0x16,
            chat_suggestions = 0x17,
            plugin_message = 0x18,
            damage_event = 0x19,
            delete_message = 0x1A,
            disconnect = 0x1B,
            disguised_chat_message = 0x1C,
            entity_event = 0x1D,
            explosion = 0x1E,
            unload_chunk = 0x1F,
            game_event = 0x20,
            open_horse_screen = 0x21,
            hurt_animation = 0x22,
            world_border_init = 0x23,
            keep_alive = 0x24,
            chunk_data_and_update_light = 0x25,
            world_event = 0x26,
            particle = 0x27,
            update_light = 0x28,
            login = 0x29,
            map_data = 0x2A,
            merchant_offers = 0x2B,
            update_entity_position = 0x2C,
            update_entity_position_and_rotation = 0x2D,
            update_entity_rotation = 0x2E,
            move_vehicle = 0x2F,
            open_book = 0x30,
            open_screen = 0x31,
            open_sign_editor = 0x32,
            ping = 0x33,
            ping_response = 0x34,
            place_ghost_recipe = 0x35,
            player_abilities = 0x36,
            player_chat_message = 0x37,
            end_combat = 0x38,
            enter_combat = 0x39,
            combat_death = 0x3A,
            player_info_remove = 0x3B,
            player_info_update = 0x3C,
            look_at = 0x3D,
            synchronize_player_position = 0x3E,
            update_recipe_book = 0x3F,
            remove_entities = 0x40,
            remove_entity_effect = 0x41,
            resource_pack = 0x42,
            respawn = 0x43,
            set_head_rotation = 0x44,
            update_section_blocks = 0x45,
            select_advancements_tab = 0x46,
            server_data = 0x47,
            set_action_bar_text = 0x48,
            set_border_center = 0x49,
            set_border_lerp_size = 0x4A,
            set_border_size = 0x4B,
            set_border_warning_delay = 0x4C,
            set_border_warning_distance = 0x4D,
            set_camera = 0x4E,
            set_held_item = 0x4F,
            set_center_chunk = 0x50,
            set_render_distance = 0x51,
            set_default_spawn_position = 0x52,
            display_objective = 0x53,
            set_entity_metadata = 0x54,
            link_entities = 0x55,
            set_entity_velocity = 0x56,
            set_equipment = 0x57,
            set_experience = 0x58,
            set_health = 0x59,
            update_objectives = 0x5A,
            set_passengers = 0x5B,
            update_teams = 0x5C,
            update_score = 0x5D,
            set_simulation_distance = 0x5E,
            set_subtitle_text = 0x5F,
            update_time = 0x60,
            set_title_text = 0x61,
            set_title_animation_times = 0x62,
            entity_sound_effect = 0x63,
            sound_effect = 0x64,
            start_configuration = 0x65,
            stop_sound = 0x66,
            system_chat_message = 0x67,
            set_tab_list_header_and_footer = 0x68,
            tag_query_response = 0x69,
            pickup_item = 0x6A,
            teleport_entity = 0x6B,
            update_advancements = 0x6C,
            update_attributes = 0x6D,
            entity_effect = 0x6E,
            update_recipes = 0x6F,
            update_tags = 0x70,
        };
        bundle_delimeter: void,
        spawn_entity: struct {
            entity_id: VarI32,
            entity_uuid: Uuid,
            type: VarI32,
            position: V3(f64),
            pitch: Angle,
            yaw: Angle,
            head_yaw: Angle,
            data: VarI32,
            velocity: V3(i16),
        },
        spawn_experience_orb: struct {
            entity_id: VarI32,
            position: V3(f64),
            count: i16,
        },
        entity_animation: struct {
            entity_id: VarI32,
            animation: enum(u8) {
                swing_main_arm = 0,
                leave_bed = 2,
                swing_off_hand = 3,
                critical_effect = 4,
                magic_critical_effect = 5,
            },
        },
        award_statistics: PrefixedArray(VarI32, struct {
            category: Enum(VarI32, enum(i32) {
                mined = 0,
                crafted = 1,
                used = 2,
                broken = 3,
                picked_up = 4,
                dropped = 5,
                killed = 6,
                killed_by = 7,
                custom = 8,
            }),
            statistic: Enum(VarI32, enum(i32) {
                leave_game = 0,
                play_one_minute = 1,
                time_since_death = 2,
                time_since_rest = 3,
                sneak_time = 4,
                walk_one_cm = 5,
                crouch_one_cm = 6,
                sprint_one_cm = 7,
                walk_on_water_one_cm = 8,
                fall_one_cm = 9,
                climb_one_cm = 10,
                fly_one_cm = 11,
                walk_under_water_one_cm = 12,
                minecart_one_cm = 13,
                boat_one_cm = 14,
                pig_one_cm = 15,
                horse_one_cm = 16,
                aviate_one_cm = 17,
                swim_one_cm = 18,
                strider_one_cm = 19,
                jump = 20,
                drop = 21,
                damage_dealt = 22,
                damage_dealt_absorbed = 23,
                damage_dealt_resisted = 24,
                damage_taken = 25,
                damage_blocked_by_shield = 26,
                damage_absorbed = 27,
                damage_resisted = 28,
                deaths = 29,
                mob_kills = 30,
                animals_bred = 31,
                player_kills = 32,
                fish_caught = 33,
                talked_to_villager = 34,
                traded_with_villager = 35,
                eat_cake_slice = 36,
                fill_cauldron = 37,
                use_cauldron = 38,
                clean_armor = 39,
                clean_banner = 40,
                clean_shulker_box = 41,
                interact_with_brewingstand = 42,
                interact_with_beacon = 43,
                inspect_dropper = 44,
                inspect_hopper = 45,
                inspect_dispenser = 46,
                play_noteblock = 47,
                tune_noteblock = 48,
                pot_flower = 49,
                trigger_trapped_chest = 50,
                open_enderchest = 51,
                enchant_item = 52,
                play_record = 53,
                interact_with_furnace = 54,
                interact_with_crafting_table = 55,
                open_chest = 56,
                sleep_in_bed = 57,
                open_shulker_box = 58,
                open_barrel = 59,
                interact_with_blast_furnace = 60,
                interact_with_smoker = 61,
                interact_with_lectern = 62,
                interact_with_campfire = 63,
                interact_with_cartography_table = 64,
                interact_with_loom = 65,
                interact_with_stonecutter = 66,
                bell_ring = 67,
                raid_trigger = 68,
                raid_win = 69,
                interact_with_anvil = 70,
                interact_with_grindstone = 71,
                target_hit = 72,
                interact_with_smithing_table = 73,
            }),
            value: VarI32,
        }, .{}),
        acknowledge_block_change: VarI32,
        set_block_destroy_stage: struct {
            entity_id: VarI32,
            location: Position,
            destroy_stage: u8,
        },
        block_entity_data: struct {
            location: Position,
            type: VarI32,
            data: nbt.Named(null, nbt.Dynamic(.any, MaxNbtDepth)),
        },
        block_action: struct {
            location: Position,
            action_id: u8,
            action_parameter: u8,
            block_type: VarI32,
        },
        block_update: struct {
            location: Position,
            block_id: VarI32,
        },
        boss_bar: struct {
            uuid: Uuid,
            action: TaggedUnion(VarU7, union(Actions) {
                const Color = Enum(VarU7, enum(u7) {
                    pink = 0,
                    blue = 1,
                    red = 2,
                    green = 3,
                    yellow = 4,
                    purple = 5,
                    white = 6,
                });
                const Division = Enum(VarU7, enum(u7) {
                    none = 0,
                    notches6 = 1,
                    notches10 = 2,
                    notches12 = 3,
                    notches20 = 4,
                });
                const Flags = packed struct(u8) {
                    darken_sky: bool,
                    dragon_bar: bool,
                    create_fog: bool,
                    _u: u5 = 0,
                };
                const Actions = enum(u7) {
                    add = 0,
                    remove = 1,
                    update_health = 2,
                    update_title = 3,
                    update_style = 4,
                    update_flags = 5,
                };
                add: struct {
                    title: ChatString,
                    health: f32,
                    color: Color,
                    division: Division,
                    flags: Flags,
                },
                remove: void,
                update_health: f32,
                update_title: ChatString,
                update_style: struct {
                    color: Color,
                    division: Division,
                },
                update_flags: Flags,
            }),
        },
        change_difficulty: struct {
            difficulty: Difficulty,
            locked: bool,
        },
        chunk_batch_finished: VarI32,
        chunk_batch_start: void,
        chunk_biomes: PrefixedArray(VarI32, struct {
            chunk_x: i32,
            chunk_y: i32,
            data: serde.ByteLimited(VarI32, Remaining(
                struct { biomes: PalettedContainer(.biome) },
                .{ .est_size = 16 },
            ), .{}),
        }, .{}),
        clear_titles: bool,
        command_suggestions_response: struct {
            id: VarI32,
            start: VarI32,
            length: VarI32,
            matches: PrefixedArray(VarI32, struct {
                match: PString(32767),
                tooltip: ?ChatString,
            }, .{}),
        },
        commands: struct {
            nodes: PrefixedArray(VarI32, CommandNode, .{}),
            root_index: VarI32,
        },
        close_container: struct {
            window_id: u8,
        },
        set_container_content: struct {
            window_id: u8,
            state_id: VarI32,
            slots: PrefixedArray(VarI32, Slot, .{}),
            carried_item: Slot,
        },
        set_container_property: struct {
            window_id: u8,
            property: i16,
            value: i16,
        },
        set_container_slot: struct {
            window_id: i8,
            state_id: VarI32,
            slot: i16,
            slot_data: Slot,
        },
        set_cooldown: struct {
            item_id: VarI32,
            cooldown_ticks: VarI32,
        },
        chat_suggestions: struct {
            action: Enum(VarU7, enum(u7) { add = 0, remove = 1, set = 2 }),
            entries: PrefixedArray(VarI32, PString(32767), .{}),
        },
        plugin_message: struct {
            channel: Identifier,
            data: Remaining(u8, .{}),
        },
        damage_event: struct {
            entity_id: VarI32,
            source_type_id: VarI32,
            source_cause_id: PlusOne(serde.ConstantOptional(VarI32, 0, null)),
            source_direct_id: PlusOne(serde.ConstantOptional(VarI32, 0, null)),
            source_position: ?V3(f64),
        },
        delete_message: union(enum) {
            pub const IdSpec = PlusOne(serde.ConstantOptional(VarI32, 0, null));
            pub const SignatureSpec = serde.Array([256]u8);
            pub const UT = @This();
            pub const E = IdSpec.E || SignatureSpec.E;

            message_id: @typeInfo(IdSpec.UT).Optional.child,
            signature: SignatureSpec.UT,

            pub fn write(writer: anytype, in: UT) !void {
                switch (in) {
                    .message_id => |id| try IdSpec.write(writer, id),
                    .signature => |sig| {
                        try VarI32.write(writer, 0);
                        try SignatureSpec.write(writer, sig);
                    },
                }
            }
            pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
                var id_: IdSpec.UT = undefined;
                try IdSpec.read(reader, &id_, a);
                if (id_) |id| {
                    out.* = .{ .message_id = id };
                } else {
                    out.* = .{ .signature = undefined };
                    try SignatureSpec.read(reader, &out.signature, a);
                }
            }
            pub fn deinit(self: *UT, _: Allocator) void {
                self.* = undefined;
            }
            pub fn size(self: UT) usize {
                return switch (self) {
                    .message_id => |id| IdSpec.size(id),
                    .signature => |sig| VarI32.size(0) + SignatureSpec.size(sig),
                };
            }
        },
        disconnect: ChatString,
        disguised_chat_message: struct {
            message: ChatString,
            chat_type: VarI32,
            sender_name: ChatString,
            target_name: ?ChatString,
        },
        entity_event: struct {
            entity_id: i32,
            entity_status: i8,
        },
        explosion: struct {
            position: V3(f64),
            strength: f32,
            records: PrefixedArray(VarI32, V3(i8), .{}),
            player_motion: V3(f32),
        },
        unload_chunk: struct {
            chunk_z: i32,
            chunk_x: i32,
        },
        game_event: union(Event) {
            const Event = enum(u8) {
                no_respawn_block = 0,
                begin_raining = 1,
                end_raining = 2,
                change_gamemode = 3,
                win_game = 4,
                demo = 5,
                arrow_hit_player = 6,
                rain_level_change = 7,
                thunder_level_change = 8,
                play_pufferfish_sting_sound = 9,
                play_elder_guardian_appearance = 10,
                enable_respawn_screen = 11,
                limited_crafting = 12,
            };
            no_respawn_block: f32,
            begin_raining: f32,
            end_raining: f32,
            change_gamemode: serde.MappedEnum(struct {
                pub const survival = 0;
                pub const creative = 1;
                pub const adventure = 2;
                pub const spectator = 3;
            }, f32, null),
            win_game: serde.MappedEnum(struct {
                pub const just_respawn = 0;
                pub const roll_credits = 1;
            }, f32, null),
            demo: serde.MappedEnum(struct {
                pub const welcome = 0;
                pub const movement_controls = 101;
                pub const jump_control = 102;
                pub const inventory_control = 103;
                pub const screenshot_and_over = 104;
            }, f32, null),
            arrow_hit_player: f32,
            rain_level_change: f32,
            thunder_level_change: f32,
            play_pufferfish_sting_sound: f32,
            play_elder_guardian_appearance: f32,
            enable_respawn_screen: serde.MappedEnum(struct {
                pub const screen = 0;
                pub const immediate = 1;
            }, f32, null),
            limited_crafting: serde.MappedEnum(struct {
                pub const disable = 0;
                pub const enable = 1;
            }, f32, null),
        },
        open_horse_screen: struct {
            window_id: u8,
            slot_count: VarI32,
            entity_id: i32,
        },
        hurt_animation: struct {
            entity_id: VarI32,
            yaw: f32,
        },
        world_border_init: struct {
            x: f64,
            z: f64,
            old_diameter: f64,
            new_diameter: f64,
            speed: VarI64,
            portal_teleport_boundary: VarI32,
            warning_blocks: VarI32,
            warning_time: VarI32,
        },
        keep_alive: i64,
        chunk_data_and_update_light: struct {
            chunk_x: i32,
            chunk_z: i32,
            heightmaps: nbt.Named(null, struct {
                motion_blocking: nbt.WithName(
                    "MOTION_BLOCKING",
                    nbt.Wrap(HeightMap, .long_array),
                ),
                world_surface: nbt.WithName(
                    "WORLD_SURFACE",
                    ?nbt.Wrap(HeightMap, .long_array),
                ),
            }),
            data: serde.ByteLimited(
                VarI32,
                Remaining(ChunkSection, .{ .est_size = 16 }),
                .{},
            ),
            block_entities: PrefixedArray(VarI32, BlockEntity, .{}),
            light_levels: LightLevels,
        },
        world_event: struct {
            p: serde.Pass(
                WorldEventId,
                serde.Pair(struct {
                    location: Position,
                }, WorldEvent),
            ),
            disable_relative_volume: bool,
        },
        particle: serde.Pass(ParticleId, serde.Pair(struct {
            long_distance: bool,
            position: V3(f64),
            offset: V3(f32),
            max_speed: f32,
            count: i32,
        }, Particle)),
        update_light: struct {
            chunk_x: VarI32,
            chunk_y: VarI32,
            light_levels: LightLevels,
        },
        login: struct {
            entity_id: i32,
            is_hardcore: bool,
            dimensions: PrefixedArray(VarI32, DimensionSpec, .{}),
            max_players: VarI32,
            view_distance: VarI32,
            simulation_distance: VarI32,
            reduced_debug_info: bool,
            enable_respawn_screen: bool,
            do_limited_crafting: bool,
            respawn: RespawnSpec,
        },
        map_data: struct {
            map_id: VarI32,
            scale: i8,
            locked: bool,
            icons: ?PrefixedArray(VarI32, struct {
                type: serde.MappedEnum(struct {
                    pub const white_arrow = 0;
                    pub const green_arrow = 1;
                    pub const red_arrow = 2;
                    pub const blue_arrow = 3;
                    pub const white_cross = 4;
                    pub const red_pointer = 5;
                    pub const white_circle = 6;
                    pub const small_white_circle = 7;
                    pub const mansion = 8;
                    pub const temple = 9;
                    pub const white_banner = 10;
                    pub const orange_banner = 11;
                    pub const magenta_banner = 12;
                    pub const light_blue_banner = 13;
                    pub const yellow_banner = 14;
                    pub const lime_banner = 15;
                    pub const pink_banner = 16;
                    pub const gray_banner = 17;
                    pub const light_gray_banner = 18;
                    pub const cyan_banner = 19;
                    pub const purple_banner = 20;
                    pub const blue_banner = 21;
                    pub const brown_banner = 22;
                    pub const green_banner = 23;
                    pub const red_banner = 24;
                    pub const black_banner = 25;
                    pub const treasure_marker = 26;
                }, VarI32, null),
                x: i8,
                z: i8,
                direction: serde.Casted(i8, u4),
                display_name: ?ChatString,
            }, .{}),
            properties: struct {
                pub const RestSpec = serde.Struct(struct {
                    rows: u8,
                    x: i8,
                    z: i8,
                    data: PrefixedArray(VarI32, u8, .{}),
                });

                columns: u8,
                rest: RestSpec.UT,

                pub const UT = ?@This();
                pub const E = RestSpec.E || error{EndOfStream};

                pub fn write(writer: anytype, in_: UT) !void {
                    if (in_) |in| {
                        try serde.Num(u8, .big).write(writer, in.columns);
                        try RestSpec.write(writer, in.rest);
                    } else {
                        try serde.Num(u8, .big).write(writer, 0);
                    }
                }
                pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
                    var columns: u8 = undefined;
                    try serde.Num(u8, .big).read(reader, &columns, undefined);
                    if (columns == 0) {
                        out.* = null;
                    } else {
                        out.* = .{
                            .columns = columns,
                            .rest = undefined,
                        };
                        try RestSpec.read(reader, &out.*.?.rest, a);
                    }
                }
                pub fn deinit(self_: *UT, a: Allocator) void {
                    if (self_.*) |*self| RestSpec.deinit(&self.rest, a);
                    self_.* = undefined;
                }
                pub fn size(self_: UT) usize {
                    return 1 + if (self_) |self| RestSpec.size(self) else 0;
                }
            },
        },
        merchant_offers: struct {
            window_id: VarI32,
            trades: PrefixedArray(VarI32, struct {
                input_item_1: Slot,
                output_item: Slot,
                input_item_2: Slot,
                trade_disabled: bool,
                uses: i32,
                max_uses: i32,
                xp: i32,
                special_price: i32,
                price_multiplier: f32,
                demand: i32,
            }, .{}),
            villager_level: VillagerLevel,
            experience: VarI32,
            is_regular_villager: VarI32,
            can_restack: bool,
        },
        update_entity_position: struct {
            entity_id: VarI32,
            delta: V3(i16),
            on_ground: bool,
        },
        update_entity_position_and_rotation: struct {
            entity_id: VarI32,
            delta: V3(i16),
            yaw: Angle,
            pitch: Angle,
            on_ground: bool,
        },
        update_entity_rotation: struct {
            entity_id: VarI32,
            yaw: Angle,
            pitch: Angle,
            on_ground: bool,
        },
        move_vehicle: struct {
            position: V3(f64),
            yaw: f32,
            pitch: f32,
        },
        open_book: serde.Enum(VarU7, enum(u7) { main_hand = 0, off_hand = 1 }),
        open_screen: struct {
            window_id: VarI32,
            window_type: serde.MappedEnum(struct {
                pub const generic_9x1 = 0;
                pub const generic_9x2 = 1;
                pub const generic_9x3 = 2;
                pub const generic_9x4 = 3;
                pub const generic_9x5 = 4;
                pub const generic_9x6 = 5;
                pub const generic_3x3 = 6;
                pub const anvil = 7;
                pub const beacon = 8;
                pub const blast_furnace = 9;
                pub const brewing_stand = 10;
                pub const crafting = 11;
                pub const enchantment = 12;
                pub const furnace = 13;
                pub const grindstone = 14;
                pub const hopper = 15;
                pub const lectern = 16;
                pub const loom = 17;
                pub const merchant = 18;
                pub const shulker_box = 19;
                pub const smithing = 20;
                pub const smoker = 21;
                pub const cartography = 22;
                pub const stonecutter = 23;
            }, VarI32, null),
            window_title: ChatString,
        },
        open_sign_editor: struct {
            location: Position,
            is_front_text: bool,
        },
        ping: i32,
        ping_response: i64,
        place_ghost_recipe: struct {
            window_id: i8,
            recipe: Identifier,
        },
        player_abilities: struct {
            flags: PlayerAbilitiesFlags,
            flying_speed: f32,
            fov_modifier: f32,
        },
        player_chat_message: struct {
            sender: Uuid,
            index: VarI32,
            message_signature: ?[256]u8,
            message: PString(256),
            timestamp: i64,
            salt: i64,
            previous_messages: PrefixedArray(VarI32, union(enum) {
                // TODO: make this an OptionalUnion
                pub const ArraySpec = serde.Array([256]u8);

                message_id: VarI32.UT,
                signature: ArraySpec.UT,

                pub const UT = ?@This();
                pub const E = ArraySpec.E || VarI32.E;

                pub fn write(writer: anytype, in: UT) !void {
                    switch (in) {
                        .message_id => |id| try VarI32.write(writer, id + 1),
                        .signature => |sig| {
                            try VarI32.write(writer, 0);
                            try ArraySpec.write(writer, sig);
                        },
                    }
                }
                pub fn read(reader: anytype, out: *UT, _: Allocator) !void {
                    var message_id: VarI32.UT = undefined;
                    try VarI32.read(reader, &message_id, undefined);
                    if (message_id == 0) {
                        out.* = .{ .signature = undefined };
                        try ArraySpec.read(reader, &out.*.?.signature, undefined);
                    } else {
                        out.* = .{ .message_id = message_id - 1 };
                    }
                }
                pub fn deinit(self: *UT, _: Allocator) void {
                    self.* = undefined;
                }
                pub fn size(self: UT) usize {
                    return switch (self) {
                        .message_id => |id| VarI32.size(id + 1),
                        .signature => |sig| VarI32.size(0) + ArraySpec.size(sig),
                    };
                }
            }, .{ .max = 20 }),
            unsigned_content: ?ChatString,
            filter: serde.TaggedUnion(VarU7, union(FilterType) {
                pub const FilterType = enum(u7) {
                    pass_through = 0,
                    fully_filtered = 1,
                    partially_filtered = 2,
                };
                pass_through: void,
                fully_filtered: void,
                partially_filtered: BitSet,
            }),
            chat_type: VarI32,
            sender_name: ChatString,
            target_name: ?ChatString,
        },
        end_combat: struct {
            duration: VarI32,
        },
        enter_combat: void,
        combat_death: struct {
            player_id: VarI32,
            message: ChatString,
        },
        player_info_remove: PrefixedArray(VarI32, Uuid, .{}),
        player_info_update: struct {
            pub const ActionsSpec = serde.Spec(packed struct(u8) {
                add_player: bool,
                initialize_chat: bool,
                update_gamemode: bool,
                update_listed: bool,
                update_latency: bool,
                update_display_name: bool,
                _u: u2 = 0,
            });
            pub const AddPlayerSpec = serde.Struct(struct {
                name: PString(16),
                properties: PrefixedArray(VarI32, struct {
                    name: PString(32767),
                    value: PString(32767),
                    signature: ?PString(32767),
                }, .{}),
            });
            pub const InitializeChatSpec = serde.Optional(struct {
                chat_session_id: Uuid,
                public_key: PublicKey,
            });
            pub const UpdateDisplayNameSpec = serde.Optional(ChatString);
            pub const PlayerAction = struct {
                uuid: Uuid.UT,
                add_player: ?AddPlayerSpec.UT,
                initialize_chat: ?InitializeChatSpec.UT,
                update_gamemode: ?VarI32.UT,
                update_listed: ?bool,
                update_latency: ?VarI32.UT,
                update_display_name: ?UpdateDisplayNameSpec.UT,
            };

            pub const UT = struct {
                actions: ActionsSpec.UT,
                player_actions: []PlayerAction,
            };
            pub const E = ActionsSpec.E || AddPlayerSpec.E ||
                InitializeChatSpec.E || UpdateDisplayNameSpec.E || VarI32.E ||
                Uuid.E || serde.Casted(VarI32, usize).E;
            const action_specs = .{
                .{ "add_player", AddPlayerSpec },
                .{ "initialize_chat", InitializeChatSpec },
                .{ "update_gamemode", VarI32 },
                .{ "update_listed", serde.Bool },
                .{ "update_latency", VarI32 },
                .{ "update_display_name", UpdateDisplayNameSpec },
            };

            pub fn write(writer: anytype, in: UT) !void {
                try ActionsSpec.write(writer, in.actions);
                try VarI32.write(writer, @intCast(in.player_actions.len));
                for (in.player_actions) |player_action| {
                    try Uuid.write(writer, player_action.uuid);
                    inline for (action_specs) |pair| {
                        if (@field(player_action, pair[0])) |action_field| {
                            try pair[1].write(writer, action_field);
                        }
                    }
                }
            }
            pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
                try ActionsSpec.read(reader, &out.actions, undefined);
                var len: usize = undefined;
                try serde.Casted(VarI32, usize).read(reader, &len, undefined);
                out.player_actions = try a.alloc(PlayerAction, len);
                errdefer a.free(out.player_actions);
                for (out.player_actions, 0..) |*player_action, i| {
                    try Uuid.read(reader, &player_action.uuid, undefined);
                    errdefer {
                        var j = i;
                        while (j > 0) {
                            j -= 1;
                            comptime var k = action_specs.len;
                            inline while (k > 0) {
                                k -= 1;
                                const pair = action_specs[k];
                                if (@field(out.player_actions[j], pair[0])) |*item| {
                                    pair[1].deinit(item, a);
                                }
                            }
                        }
                    }
                    inline for (action_specs, 0..) |pair, j| {
                        if (@field(out.actions, pair[0])) {
                            errdefer {
                                comptime var k = j;
                                inline while (k > 0) {
                                    k -= 1;
                                    const pair_e = action_specs[k];
                                    if (@field(out.player_actions[j], pair_e[0])) |*item| {
                                        pair_e[1].deinit(item, a);
                                    }
                                }
                            }
                            @field(player_action, pair[0]) = @as(pair[1].UT, undefined);
                            try pair[1].read(reader, &@field(player_action, pair[0]).?, a);
                        } else {
                            @field(player_action, pair[0]) = null;
                        }
                    }
                }
            }
            pub fn deinit(self: *UT, a: Allocator) void {
                var i = self.player_actions.len;
                while (i > 0) {
                    i -= 1;
                    comptime var j = action_specs.len;
                    inline while (j > 0) {
                        j -= 1;
                        const pair = action_specs[j];
                        if (@field(self.player_actions[i], pair[0])) |*item| {
                            pair[1].deinit(item, a);
                        }
                    }
                }
                a.free(self.player_actions);
                self.* = undefined;
            }
            pub fn size(self: UT) usize {
                var total = ActionsSpec.size(self.actions) +
                    VarI32.size(@intCast(self.player_actions.len));
                for (self.player_actions) |player_action| {
                    total += Uuid.size(player_action.uuid);
                    inline for (action_specs) |pair| {
                        if (@field(player_action, pair[0])) |action_field| {
                            total += pair[1].size(action_field);
                        }
                    }
                }
                return total;
            }
        },
        look_at: struct {
            const FeetOrEyesSpec = serde.Enum(VarU7, enum(u7) { feet = 0, eyes = 1 });
            from: FeetOrEyesSpec,
            target: V3(f64),
            entity: ?struct {
                id: VarI32,
                from: FeetOrEyesSpec,
            },
        },
        synchronize_player_position: struct {
            position: V3(f64),
            yaw: f32,
            pitch: f32,
            relative: packed struct(u8) {
                x: bool,
                y: bool,
                z: bool,
                pitch: bool,
                yaw: bool,
                _u: u3 = 0,
            },
            teleport_id: VarI32,
        },
        update_recipe_book: serde.TaggedUnion(VarU7, union(Action) {
            const Action = enum(u7) { init = 0, add = 1, remove = 2 };

            const RecipeBook = struct {
                const KindStatus = struct { open: bool, filter: bool };
                crafting: KindStatus,
                smelting: KindStatus,
                blast_furnace: KindStatus,
                smoker: KindStatus,
            };

            init: struct {
                book: RecipeBook,
                recipe_ids_1: PrefixedArray(VarI32, Identifier, .{}),
                recipe_ids_2: PrefixedArray(VarI32, Identifier, .{}),
            },
            add: struct {
                book: RecipeBook,
                recipe_ids: PrefixedArray(VarI32, Identifier, .{}),
            },
            remove: struct {
                book: RecipeBook,
                recipe_ids: PrefixedArray(VarI32, Identifier, .{}),
            },
        }),
        remove_entities: PrefixedArray(VarI32, VarI32, .{}),
        remove_entity_effect: struct {
            entity_id: VarI32,
            effect: serde.Enum(serde.Casted(VarI32, Effect.Id), Effect),
        },
        resource_pack: struct {
            url: PString(32767),
            hash: PString(40),
            forced: bool,
            prompt_message: ?ChatString,
        },
        respawn: struct {
            data: RespawnSpec,
            data_kept: packed struct(u8) {
                keep_attributes: bool,
                keep_metadata: bool,
                _u: u6 = 0,
            },
        },
        set_head_rotation: struct {
            entity_id: VarI32,
            head_yaw: Angle,
        },
        update_section_blocks: struct {
            section_position: packed struct(u64) {
                // TODO: is y signed? wiki.vg doesnt say, but since mincecraft is java i will assume so for now
                y: i20,
                z: i22,
                x: i22,
            },
            blocks: PrefixedArray(
                VarI32,
                serde.BitCasted(VarI64, packed struct(u64) {
                    // probably not signed cause this is a chunk section
                    y: u4,
                    z: u4,
                    x: u4,
                    state_id: BlockState.Id,
                    // this doesnt even take up 32 bits; (15 + 4 + 4 + 4) why use longs for this?
                    _u: u37 = 0,
                }),
                .{},
            ),
        },
        select_advancements_tab: ?serde.StringEnum(struct {
            pub const story = "minecraft:story/root";
            pub const nether = "minecraft:nether/root";
            pub const end = "minecraft:end/root";
            pub const adventure = "minecraft:adventure/root";
            pub const husbandry = "minecraft:husbandry/root";
        }, Identifier),
        server_data: struct {
            motd: ChatString,
            icon: ?PrefixedArray(VarI32, u8, .{}),
            enforces_secure_chat: bool,
        },
        set_action_bar_text: ChatString,
        set_border_center: struct {
            x: f64,
            z: f64,
        },
        set_border_lerp_size: struct {
            old_diameter: f64,
            new_diameter: f64,
            speed: VarI64,
        },
        set_border_size: struct {
            diameter: f64,
        },
        set_border_warning_delay: struct {
            time: VarI32,
        },
        set_border_warning_distance: struct {
            blocks: VarI32,
        },
        set_camera: struct {
            camera_id: VarI32,
        },
        set_held_item: struct {
            slot: u8,
        },
        set_center_chunk: struct {
            chunk_x: VarI32,
            chunk_z: VarI32,
        },
        set_render_distance: VarI32,
        set_default_spawn_position: struct {
            location: Position,
            angle: f32,
        },
        display_objective: struct {
            position: VarI32,
            score_name: PString(32767),
        },
        set_entity_metadata: struct {
            entity_id: VarI32,
            metadata: struct {
                pub const EntrySpec = serde.TaggedUnion(VarU7, union(EntryId) {
                    pub const EntryId = enum(u7) {
                        byte = 0,
                        varint = 1,
                        varlong = 2,
                        float = 3,
                        string = 4,
                        chat = 5,
                        opt_chat = 6,
                        slot = 7,
                        boolean = 8,
                        rotation = 9,
                        position = 10,
                        opt_position = 11,
                        direction = 12,
                        opt_uuid = 13,
                        block_id = 14,
                        opt_block_id = 15,
                        nbt = 16,
                        particle = 17,
                        villager_data = 18,
                        opt_varint = 19,
                        pose = 20,
                        cat_variant = 21,
                        frog_variant = 22,
                        opt_globalpos = 23,
                        painting_variant = 24,
                        sniffer_state = 25,
                        vector3 = 26,
                        quaternion = 27,
                    };
                    byte: i8,
                    varint: VarI32,
                    varlong: VarI64,
                    float: f32,
                    string: PString(null),
                    chat: ChatString,
                    opt_chat: ?ChatString,
                    slot: Slot,
                    boolean: bool,
                    rotation: V3(f32),
                    position: Position,
                    opt_position: ?Position,
                    direction: serde.Enum(VarU7, enum(u7) {
                        down = 0,
                        up = 1,
                        north = 2,
                        south = 3,
                        west = 4,
                        east = 5,
                    }),
                    opt_uuid: ?Uuid,
                    block_id: serde.Casted(VarI32, BlockState.Id),
                    opt_block_id: serde.ConstantOptional(
                        serde.Casted(VarI32, BlockState.Id),
                        0,
                        null,
                    ),
                    nbt: nbt.Named(null, nbt.Dynamic(.any, MaxNbtDepth)), // TODO: dont know if this is right
                    particle: serde.Pass(ParticleId, Particle),
                    villager_data: struct {
                        type: VillagerType,
                        profession: VillagerProfession,
                        level: VillagerLevel,
                    },
                    opt_varint: PlusOne(serde.ConstantOptional(VarI32, 0, null)),
                    pose: serde.Enum(VarU7, enum(u7) {
                        standing = 0,
                        fall_flying = 1,
                        sleeping = 2,
                        swimming = 3,
                        spin_attack = 4,
                        sneaking = 5,
                        long_jumping = 6,
                        dying = 7,
                        croaking = 8,
                        using_tongue = 9,
                        sitting = 10,
                        roaring = 11,
                        sniffing = 12,
                        emerging = 13,
                        digging = 14,
                    }),

                    // found in generated/reports/registries.json
                    cat_variant: serde.Enum(VarU7, enum(u7) {
                        tabby = 0,
                        black = 1,
                        red = 2,
                        siamese = 3,
                        british_shorthair = 4,
                        calico = 5,
                        persian = 6,
                        ragdoll = 7,
                        white = 8,
                        jellie = 9,
                        all_black = 10,
                    }),
                    frog_variant: serde.Enum(VarU7, enum(u7) {
                        temperate = 0,
                        warm = 1,
                        cold = 2,
                    }),
                    opt_globalpos: ?struct {
                        dimension: DimensionSpec,
                        location: Position,
                    },
                    painting_variant: serde.Enum(VarU7, enum(u7) {
                        kebab = 0,
                        aztec = 1,
                        alban = 2,
                        aztec2 = 3,
                        bomb = 4,
                        plant = 5,
                        wasteland = 6,
                        pool = 7,
                        courbet = 8,
                        sea = 9,
                        sunset = 10,
                        creebet = 11,
                        wanderer = 12,
                        graham = 13,
                        match = 14,
                        bust = 15,
                        stage = 16,
                        void = 17,
                        skull_and_roses = 18,
                        wither = 19,
                        fighters = 20,
                        pointer = 21,
                        pigscene = 22,
                        burning_skull = 23,
                        skeleton = 24,
                        earth = 25,
                        wind = 26,
                        water = 27,
                        fire = 28,
                        donkey_kong = 29,
                    }),
                    sniffer_state: serde.Enum(VarU7, enum(u7) {
                        idling = 0,
                        feeling_happy = 1,
                        scenting = 2,
                        sniffing = 3,
                        searching = 4,
                        digging = 5,
                        rising = 6,
                    }),
                    vector3: V3(f32),
                    quaternion: struct {
                        x: f32,
                        y: f32,
                        z: f32,
                        w: f32,
                    },
                });
                pub const UTEntry = struct {
                    id: u8,
                    data: EntrySpec.UT,
                };
                pub const UT = []UTEntry;
                pub const E = EntrySpec.E || error{EndOfStream};
                pub fn write(writer: anytype, in: UT) !void {
                    for (in) |entry| {
                        try writer.writeByte(entry.id);
                        try EntrySpec.write(writer, entry.data);
                    }
                    try writer.writeByte(0xFF);
                }
                pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
                    var len: u8 = 0;
                    var entries = [_]?EntrySpec.UT{null} ** 255;
                    errdefer {
                        var i = entries.len;
                        while (i > 0) {
                            i -= 1;
                            if (entries[i]) |*entry| EntrySpec.deinit(entry, a);
                        }
                    }

                    while (true) {
                        var index: u8 = try reader.readByte();
                        if (index == 0xFF) break;
                        if (entries[index]) |*existing_entry| {
                            EntrySpec.deinit(existing_entry, a);
                        } else {
                            len += 1;
                        }
                        entries[index] = @as(EntrySpec.UT, undefined);
                        try EntrySpec.read(reader, &entries[index].?, a);
                    }
                    out.* = try a.alloc(UTEntry, len);
                    var i: u8 = 0;
                    for (entries, 0..) |entry_, id| if (entry_) |entry| {
                        out.*[i] = .{
                            .id = @intCast(id),
                            .data = entry,
                        };
                        i += 1;
                    };
                }
                pub fn deinit(self: *UT, a: Allocator) void {
                    var i = self.len;
                    while (i > 0) {
                        i -= 1;
                        EntrySpec.deinit(&self.*[i].data, a);
                    }
                    a.free(self.*);
                    self.* = undefined;
                }
                pub fn size(self: UT) usize {
                    var total = 1;
                    for (self) |entry| total += 1 + EntrySpec.size(entry.data);
                    return total;
                }
            },
        },
        link_entities: struct {
            attached_entity_id: i32,
            holding_entity_id: i32,
        },
        set_entity_velocity: struct {
            entity_id: VarI32,
            velocity: V3(i16),
        },
        set_equipment: struct {
            entity_id: VarI32,
            equipment: struct {
                const EquipmentSlot = enum(u7) {
                    main_hand = 0,
                    off_hand = 1,
                    boots = 2,
                    leggings = 3,
                    chestplate = 4,
                    helmet = 5,
                };
                const EquipmentSlotSentinelSpec = serde.Spec(packed struct(u8) {
                    slot: EquipmentSlot,
                    has_another_entry: bool,
                });
                const Entry = struct {
                    slot: EquipmentSlot,
                    item: Slot.UT,
                };
                pub const UT = []Entry;
                pub const E = EquipmentSlotSentinelSpec.E || Slot.E;
                pub fn write(writer: anytype, in: UT) !void {
                    for (in, 0..) |entry, i| {
                        try EquipmentSlotSentinelSpec.write(writer, .{
                            .slot = entry.slot,
                            .has_another_entry = i == entry.len - 1,
                        });
                        try Slot.write(writer, entry.slot);
                    }
                }
                pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
                    var entries = std.ArrayList(Entry).init(a);
                    defer {
                        var i = entries.items.len;
                        while (i > 0) {
                            i -= 1;
                            Slot.deinit(&entries.items[i].item, a);
                        }
                        entries.deinit();
                    }
                    while (true) {
                        var b: EquipmentSlotSentinelSpec.UT = undefined;
                        try EquipmentSlotSentinelSpec.read(reader, &b, undefined);
                        var entry = try entries.addOne();
                        errdefer entries.items.len -= 1;
                        try Slot.read(reader, &entry.item, a);
                        errdefer Slot.deinit(&entry.item, a);
                        entry.slot = b.slot;
                        if (!b.has_another_entry) break;
                    }
                    out.* = try entries.toOwnedSlice();
                }
                pub fn deinit(self: *UT, a: Allocator) void {
                    var i = self.len;
                    while (i > 0) {
                        i -= 1;
                        Slot.deinit(&self.*[i].item, a);
                    }
                    a.free(self.*);
                    self.* = undefined;
                }
                pub fn size(self: UT) usize {
                    var total: usize = 0;
                    for (self) |entry| total += 1 + Slot.size(entry.slot);
                    return total;
                }
            },
        },
        set_experience: struct {
            bar: f32,
            level: VarI32,
            total_experience: VarI32,
        },
        set_health: struct {
            health: f32,
            food: VarI32,
            food_saturation: f32,
        },
        update_objectives: struct {
            name: PString(32767),
            value: serde.TaggedUnion(u8, union(Mode) {
                const Mode = enum(u8) {
                    create = 0,
                    remove = 1,
                    update_display_text = 2,
                };

                const Value = serde.Struct(struct {
                    value: ChatString,
                    type: serde.Enum(VarU7, enum(u7) { integer = 0, hearts = 1 }),
                });

                create: Value,
                remove: void,
                update_display_text: Value,
            }),
        },
        set_passengers: struct {
            entity_id: VarI32,
            passengers: PrefixedArray(VarI32, VarI32, .{}),
        },
        update_teams: struct {
            team_name: PString(32767),
            action: serde.TaggedUnion(u8, union(Mode) {
                const Mode = enum(u8) {
                    create = 0,
                    remove = 1,
                    update_info = 2,
                    add_entities = 3,
                    remove_entities = 4,
                };
                const TeamInfoSpec = serde.Struct(struct {
                    display_name: ChatString,
                    friendly_flags: packed struct(u8) {
                        allow_friendly_fire: bool,
                        see_invisible_team_members: bool,
                        _u: u6 = 0,
                    },
                    name_tag_visibility: serde.StringEnum(struct {
                        pub const always = "always";
                        pub const hide_for_other_teams = "hideForOtherTeams";
                        pub const hide_for_own_team = "hideForOwnTeam";
                        pub const never = "never";
                    }, PString(40)),
                    collision_rule: serde.StringEnum(struct {
                        pub const always = "always";
                        pub const push_other_teams = "pushOtherTeams";
                        pub const push_own_team = "pushOwnTeam";
                        pub const never = "never";
                    }, PString(40)),
                    color: serde.Enum(VarU7, enum(u7) {
                        black = 0,
                        dark_blue = 1,
                        dark_green = 2,
                        dark_aqua = 3,
                        dark_red = 4,
                        dark_purple = 5,
                        gold = 6,
                        gray = 7,
                        dark_gray = 8,
                        blue = 9,
                        green = 10,
                        aqua = 11,
                        red = 12,
                        light_purple = 13,
                        yellow = 14,
                        white = 15,
                        obfuscated = 16,
                        bold = 17,
                        strikethrough = 18,
                        underlined = 19,
                        italic = 20,
                        reset = 21,
                    }),
                    prefix: ChatString,
                    suffix: ChatString,
                });
                const EntitiesSpec = PrefixedArray(VarI32, PString(32767), .{});
                create: struct {
                    info: TeamInfoSpec,
                    entities: EntitiesSpec,
                },
                remove: void,
                update_info: TeamInfoSpec,
                add_entities: EntitiesSpec,
                remove_entities: EntitiesSpec,
            }),
        },
        update_score: struct {
            entity_name: PString(32767),
            action: serde.TaggedUnion(VarU7, union(Action) {
                const Action = enum(u7) { create_or_update = 0, remove = 1 };
                create_or_update: struct {
                    objective_name: PString(32767),
                    value: VarI32,
                },
                remove: struct {
                    objective_name: PString(32767),
                },
            }),
        },
        set_simulation_distance: VarI32,
        set_subtitle_text: ChatString,
        update_time: struct {
            world_age: i64,
            time_of_day: i64,
        },
        set_title_text: ChatString,
        set_title_animation_times: struct {
            fade_in: i32,
            stay: i32,
            fade_out: i32,
        },
        entity_sound_effect: struct {
            sound: serde.OptionalUnion(
                PlusOne(serde.ConstantOptional(VarI32, 0, null)),
                struct {
                    name: Identifier,
                    range: ?f32,
                },
            ),
            category: SoundCategory,
            entity_id: VarI32,
            volume: f32,
            pitch: f32,
            seed: u64,
        },
        sound_effect: struct {
            sound: serde.OptionalUnion(
                PlusOne(serde.ConstantOptional(VarI32, 0, null)),
                struct {
                    name: Identifier,
                    range: ?f32,
                },
            ),
            category: SoundCategory,
            effect_position: V3(i32),
            volume: f32,
            pitch: f32,
            seed: u64,
        },
        start_configuration: void,
        stop_sound: struct {
            pub const FlagsSpec = serde.Packed(packed struct(u8) {
                has_source: bool,
                has_sound: bool,
                _u: u6 = 0,
            }, .big);
            pub const UT = struct {
                source: ?SoundCategory.UT,
                sound: ?Identifier.UT,
            };
            pub const E = SoundCategory.E || Identifier.E;
            pub fn write(writer: anytype, in: UT) !void {
                try FlagsSpec.write(writer, .{
                    .has_source = in.source != null,
                    .has_sound = in.sound != null,
                });
                if (in.source) |v| try SoundCategory.write(writer, v);
                if (in.sound) |v| try Identifier.write(writer, v);
            }
            pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
                var bits: FlagsSpec.UT = undefined;
                try FlagsSpec.read(reader, &bits, undefined);
                if (bits.has_source) {
                    out.source = @as(SoundCategory.UT, undefined);
                    try SoundCategory.read(reader, &out.source.?, undefined);
                } else {
                    out.source = null;
                }
                if (bits.has_sound) {
                    out.sound = @as(Identifier.UT, undefined);
                    try Identifier.read(reader, &out.sound.?, a);
                } else {
                    out.sound = null;
                }
            }
            pub fn deinit(self: *UT, a: Allocator) void {
                if (self.sound) |*v| Identifier.deinit(v, a);
                if (self.source) |*v| SoundCategory.deinit(v, a);
                self.* = undefined;
            }
            pub fn size(self: UT) usize {
                return 1 +
                    (if (self.source) |v| SoundCategory.size(v) else 0) +
                    (if (self.sound) |v| Identifier.size(v) else 0);
            }
        },
        system_chat_message: struct {
            content: ChatString,
            is_action_bar: bool,
        },
        set_tab_list_header_and_footer: struct {
            header: ChatString,
            footer: ChatString,
        },
        tag_query_response: struct {
            transaction_id: VarI32,
            nbt: nbt.Dynamic(.compound, MaxNbtDepth),
        },
        pickup_item: struct {
            collected_entity_id: VarI32,
            collector_entity_id: VarI32,
            pickup_item_count: VarI32,
        },
        teleport_entity: struct {
            entity_id: VarI32,
            position: V3(f64),
            yaw: Angle,
            pitch: Angle,
            on_ground: bool,
        },
        update_advancements: struct {
            reset: bool,
            advancement_mappings: PrefixedArray(VarI32, struct {
                key: Identifier,
                value: Advancement,
            }, .{}),
            advancements_to_remove: PrefixedArray(VarI32, Identifier, .{}),
            progress_mappings: PrefixedArray(VarI32, struct {
                key: Identifier,
                value: PrefixedArray(VarI32, struct {
                    criterion_identifier: Identifier,
                    criterion_progress: struct {
                        date_of_achieving: ?i64,
                    },
                }, .{}),
            }, .{}),
        },
        update_attributes: struct {
            entity_id: VarI32,
            properties: PrefixedArray(VarI32, struct {
                key: serde.StringEnum(struct {
                    pub const max_health = "minecraft:generic.max_health";
                    pub const max_absorption = "minecraft:generic.max_absorption";
                    pub const follow_range = "minecraft:generic.follow_range";
                    pub const knockback_resistance = "minecraft:generic.knockback_resistance";
                    pub const movement_speed = "minecraft:generic.movement_speed";
                    pub const attack_damage = "minecraft:generic.attack_damage";
                    pub const armor = "minecraft:generic.armor";
                    pub const armor_toughness = "minecraft:generic.armor_toughness";
                    pub const attack_knockback = "minecraft:generic.attack_knockback";
                    pub const attack_speed = "minecraft:generic.attack_speed";
                    pub const luck = "minecraft:generic.luck";
                    pub const jump_strength = "minecraft:horse.jump_strength";
                    pub const flying_speed = "minecraft:generic.flying_speed";
                    pub const spawn_reinforcements = "minecraft:zombie.spawn_reinforcements";
                }, Identifier),
                value: f64,
                modifiers: PrefixedArray(VarI32, struct {
                    uuid: Uuid,
                    amount: f64,
                    operation: enum(u8) {
                        addsub = 0,
                        addsub_percent = 1,
                        mul_percent = 2,
                    },
                }, .{}),
            }, .{}),
        },
        entity_effect: struct {
            entity_id: VarI32,
            effect: serde.Enum(serde.Casted(VarI32, Effect.Id), Effect),
            amplifier: i8,
            flags: packed struct(u8) {
                ambient: bool,
                show_particles: bool,
                show_icon: bool,
                _u: u5 = 0,
            },
            factor_codec: ?nbt.Named(null, struct {
                padding_duration: i32,
                factor_start: f32,
                factor_target: f32,
                factor_current: f32,
                effect_changed_timestamp: i32,
                factor_previous_frame: f32,
                had_effect_last_tick: bool,
            }),
        },
        update_recipes: PrefixedArray(VarI32, serde.Pass(RecipeType, serde.Pair(
            Identifier,
            serde.Union(union(RecipeType.UT) {
                pub const Ingredients = PrefixedArray(VarI32, Ingredient, .{});
                pub const Group = PString(32767);
                pub const CookingSpec = serde.Struct(struct {
                    group: Group,
                    category: serde.Enum(VarU7, enum(u7) {
                        food = 0,
                        blocks = 1,
                        misc = 2,
                    }),
                    ingredient: Ingredient,
                    result: Slot,
                    experience: f32,
                    cooking_time: VarI32,
                });
                crafting_shapeless: struct {
                    group: Group,
                    category: RecipeCategory,
                    ingredients: Ingredients,
                    result: Slot,
                },
                crafting_shaped: struct {
                    width: usize,
                    height: usize,
                    group: Group.UT,
                    category: RecipeCategory.UT,
                    ingredients: []Ingredient.UT,
                    result: Slot.UT,
                    show_notification: bool,

                    const LenSpec = serde.Casted(VarI32, usize);
                    pub const UT = @This();
                    pub const E = LenSpec.E || PString(32767).E || RecipeCategory.E ||
                        Ingredients.E || serde.Bool.E || Slot.E;

                    pub fn write(writer: anytype, in: UT) !void {
                        try LenSpec.write(writer, in.width);
                        try LenSpec.write(writer, in.height);
                        try Group.write(writer, in.group);
                        try RecipeCategory.write(writer, in.category);
                        for (in.ingredients) |item| try Ingredient.write(writer, item);
                        try Slot.write(writer, in.result);
                        try serde.Bool.write(writer, in.show_notification);
                    }
                    pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
                        try LenSpec.read(reader, &out.width, undefined);
                        try LenSpec.read(reader, &out.height, undefined);
                        try Group.read(reader, &out.group, a);
                        errdefer Group.deinit(&out.group, a);
                        try RecipeCategory.read(reader, &out.category, undefined);

                        out.ingredients = try a.alloc(Ingredient.UT, out.width * out.height);
                        errdefer a.free(out.ingredients);
                        for (out.ingredients, 0..) |*item, i| {
                            errdefer {
                                var j = i;
                                while (j > 0) {
                                    j -= 1;
                                    Ingredient.deinit(&out.ingredients[j], a);
                                }
                            }
                            try Ingredient.read(reader, item, a);
                        }
                        errdefer {
                            var i = out.ingredients.len;
                            while (i > 0) {
                                i -= 1;
                                Ingredient.deinit(&out.ingredients[i], a);
                            }
                        }

                        try Slot.read(reader, &out.result, a);
                        errdefer Slot.deinit(&out.result, a);
                        try serde.Bool.read(reader, &out.show_notification, undefined);
                    }
                    pub fn deinit(self: *UT, a: Allocator) void {
                        Slot.deinit(&self.result, a);
                        var i = self.ingredients.len;
                        while (i > 0) {
                            i -= 1;
                            Ingredient.deinit(&self.ingredients[i], a);
                        }
                        a.free(self.ingredients);
                        Group.deinit(&self.group, a);
                        self.* = undefined;
                    }
                    pub fn size(self: UT) usize {
                        var total = LenSpec.size(self.width) + LenSpec.size(self.height) +
                            Group.size(self.group) + RecipeCategory.size(self.category);
                        for (self.ingredients) |item| total += Ingredient.size(item);
                        return total + Slot.size(self.result) +
                            serde.Bool.size(self.show_notification);
                    }
                },
                crafting_special_armordye: RecipeCategory,
                crafting_special_bookcloning: RecipeCategory,
                crafting_special_mapcloning: RecipeCategory,
                crafting_special_mapextending: RecipeCategory,
                crafting_special_firework_rocket: RecipeCategory,
                crafting_special_firework_star: RecipeCategory,
                crafting_special_firework_star_fade: RecipeCategory,
                crafting_special_repairitem: RecipeCategory,
                crafting_special_tippedarrow: RecipeCategory,
                crafting_special_bannerduplicate: RecipeCategory,
                crafting_special_shielddecoration: RecipeCategory,
                crafting_special_shulkerboxcoloring: RecipeCategory,
                crafting_special_suspiciousstew: RecipeCategory,
                crafting_decorated_pot: RecipeCategory,
                smelting: CookingSpec,
                blasting: CookingSpec,
                smoking: CookingSpec,
                campfire_cooking: CookingSpec,
                stonecutting: struct {
                    group: Group,
                    ingredient: Ingredient,
                    result: Slot,
                },
                smithing_transform: struct {
                    template: Ingredient,
                    base: Ingredient,
                    addition: Ingredient,
                    result: Slot,
                },
                smithing_trim: struct {
                    template: Ingredient,
                    base: Ingredient,
                    addition: Ingredient,
                },
            }),
        )), .{}),
        update_tags: Tags,
    });
    pub const SB = TaggedUnion(VarU7, union(PacketIds) {
        pub const PacketIds = enum(u7) {
            confirm_teleportation = 0x00,
            query_block_entity_tag = 0x01,
            change_difficulty = 0x02,
            acknowledge_message = 0x03,
            chat_command = 0x04,
            chat_message = 0x05,
            player_session = 0x06,
            chunk_batch_received = 0x07,
            client_status = 0x08,
            client_information = 0x09,
            command_suggestions_request = 0x0A,
            acknowledge_configuration = 0x0B,
            click_container_button = 0x0C,
            click_container = 0x0D,
            close_container = 0x0E,
            plugin_message = 0x0F,
            edit_book = 0x10,
            query_entity_tag = 0x11,
            interact = 0x12,
            jigsaw_generate = 0x13,
            keep_alive = 0x14,
            lock_difficulty = 0x15,
            set_player_position = 0x16,
            set_player_position_and_rotation = 0x17,
            set_player_rotation = 0x18,
            set_player_on_ground = 0x19,
            move_vehicle = 0x1A,
            paddle_boat = 0x1B,
            pick_item = 0x1C,
            ping_request = 0x1D,
            place_recipe = 0x1E,
            player_abilities = 0x1F,
            player_action = 0x20,
            player_command = 0x21,
            player_input = 0x22,
            pong = 0x23,
            change_recipe_book_settings = 0x24,
            set_seen_recipe = 0x25,
            rename_item = 0x26,
            resource_pack_response = 0x27,
            seen_advancements = 0x28,
            select_trade = 0x29,
            set_beacon_effect = 0x2A,
            set_held_item = 0x2B,
            program_command_block = 0x2C,
            program_command_block_minecart = 0x2D,
            set_creative_mode_slot = 0x2E,
            program_jigsaw_block = 0x2F,
            program_structure_block = 0x30,
            update_sign = 0x31,
            swing_arm = 0x32,
            teleport_to_entity = 0x33,
            use_item_on = 0x34,
            use_item = 0x35,
        };
        confirm_teleportation: struct {
            teleport_id: VarI32,
        },
        query_block_entity_tag: struct {
            transaction_id: VarI32,
            location: Position,
        },
        change_difficulty: Difficulty,
        acknowledge_message: struct {
            message_count: VarI32,
        },
        chat_command: struct {
            command: PString(256),
            timestamp: i64,
            salt: i64,
            argument_signatures: PrefixedArray(VarI32, struct {
                name: PString(16),
                signature: [256]u8,
            }, .{ .max = 8 }),
            message_count: VarI32,
            acknowledged: BitSet, // TODO: this has a maximum
        },
        chat_message: struct {
            message: PString(256),
            timestamp: i64,
            salt: i64,
            signature: ?[256]u8,
            message_count: VarI32,
            acknowledged: BitSet, // TODO: this has a maximum
        },
        player_session: struct {
            session_id: Uuid,
            public_key: PublicKey,
        },
        chunk_batch_received: struct {
            chunks_per_tick: f32,
        },
        client_status: struct {
            action: serde.Enum(VarU7, enum(u7) {
                perform_respawn = 0,
                request_stats = 1,
            }),
        },
        client_information: ClientInformation,
        command_suggestions_request: struct {
            transaction_id: VarI32,
            text: PString(32500),
        },
        acknowledge_configuration: void,
        click_container_button: struct {
            window_id: i8,
            button_id: i8,
        },
        click_container: struct {
            window_id: u8,
            state_id: VarI32,
            slot: i16,
            button: i8,
            mode: serde.Enum(VarU7, enum(u7) {
                none = 0,
                shift = 1,
                number = 2,
                creative = 3,
                drop = 4,
                drag = 5,
                double = 6,
            }),
            slots: PrefixedArray(VarI32, struct {
                number: i16,
                data: Slot,
            }, .{ .max = 128 }),
            carried_item: Slot,
        },
        close_container: struct {
            window_id: u8,
        },
        plugin_message: struct {
            channel: Identifier,
            data: Remaining(u8, .{ .max = 32767 }),
        },
        edit_book: struct {
            slot: VarI32,
            entries: PrefixedArray(VarI32, PString(8192), .{ .max = 200 }),
            title: ?PString(128),
        },
        query_entity_tag: struct {
            transaction_id: VarI32,
            entity_id: VarI32,
        },
        interact: struct {
            entity_id: VarI32,
            kind: TaggedUnion(VarU7, union(Kind) {
                const Kind = enum(u7) {
                    interact = 0,
                    attack = 1,
                    interact_at = 2,
                };
                interact: struct {
                    target: V3(f32),
                    hand: Hand,
                },
                attack: void,
                interact_at: struct {
                    hand: Hand,
                },
            }),
            sneaking: bool,
        },
        jigsaw_generate: struct {
            location: Position,
            levels: VarI32,
            keep_jigsaws: bool,
        },
        keep_alive: i64,
        lock_difficulty: bool,
        set_player_position: struct {
            x: f64,
            feet_y: f64,
            z: f64,
            on_ground: bool,
        },
        set_player_position_and_rotation: struct {
            x: f64,
            feet_y: f64,
            z: f64,
            yaw: f32,
            pitch: f32,
            on_ground: bool,
        },
        set_player_rotation: struct {
            yaw: f32,
            pitch: f32,
            on_ground: bool,
        },
        set_player_on_ground: struct {
            on_ground: bool,
        },
        move_vehicle: struct {
            position: V3(f64),
            yaw: f32,
            pitch: f32,
        },
        paddle_boat: struct {
            left_paddle_turning: bool,
            right_paddle_turning: bool,
        },
        pick_item: struct {
            slot: VarI32,
        },
        ping_request: i64,
        place_recipe: struct {
            window_id: i8,
            recipe: Identifier,
            make_all: bool,
        },
        player_abilities: PlayerAbilitiesFlags,
        player_action: struct {
            status: Enum(VarU7, enum(u7) {
                started_digging = 0,
                cancelled_digging = 1,
                finished_digging = 2,
                drop_item_stack = 3,
                drop_item = 4,
                finish_item = 5,
                swap_item = 6,
            }),
            location: Position,
            face: enum(u8) { // TODO: could we just make this the same enum as the ones with the up and down?
                bottom = 0,
                top = 1,
                north = 2,
                south = 3,
                west = 4,
                east = 5,
            },
            sequence: VarI32,
        },
        player_command: struct {
            entity_id: VarI32,
            action: Enum(VarU7, enum(u7) {
                start_sneaking = 0,
                stop_sneaking = 1,
                leave_bed = 2,
                start_sprinting = 3,
                stop_sprinting = 4,
                start_horse_jump = 5,
                stop_horse_jump = 6,
                open_horse_inventory = 7,
                start_elytra_fly = 8,
            }),
            jump_boost: VarI32,
        },
        player_input: struct {
            sideways: f32,
            forward: f32,
            flags: packed struct(u8) {
                jump: bool,
                unmount: bool,
                _u: u6 = 0,
            },
        },
        pong: i32,
        change_recipe_book_settings: struct {
            book_id: Enum(VarU7, enum(u7) {
                crafting = 0,
                furnace = 1,
                blast_furnace = 2,
                smoker = 3,
            }),
            book_open: bool,
            filter_active: bool,
        },
        set_seen_recipe: struct {
            recipe_id: Identifier,
        },
        rename_item: struct {
            item_name: PString(32767),
        },
        resource_pack_response: struct {
            result: Enum(VarU7, enum(u7) {
                success = 0,
                declined = 1,
                failed = 2,
                accepted = 3,
            }),
        },
        seen_advancements: TaggedUnion(VarU7, union(Action) {
            const Action = enum(u7) { opened_tab = 0, closed_screen = 1 };
            opened_tab: struct {
                tab_id: Identifier,
            },
            closed_screen: void,
        }),
        select_trade: struct {
            selected_slot: VarI32,
        },
        set_beacon_effect: struct {
            primary_effect: ?PotionId,
            secondary_effect: ?PotionId,
        },
        set_held_item: struct {
            slot: Slot,
        },
        program_command_block: struct {
            location: Position,
            command: PString(32767),
            mode: Enum(VarU7, enum(u7) { sequence = 0, auto = 1, redstone = 2 }),
            flags: packed struct(u8) {
                track_output: bool,
                is_conditional: bool,
                automatic: bool,
                _u: u5 = 0,
            },
        },
        program_command_block_minecart: struct {
            entity_id: VarI32,
            command: PString(32767),
            track_output: bool,
        },
        set_creative_mode_slot: struct {
            slot: i16,
            clicked_item: Slot,
        },
        program_jigsaw_block: struct {
            location: Position,
            name: Identifier,
            target: Identifier,
            pool: Identifier,
            final_state: PString(32767),
            joint_type: PString(32767),
        },
        program_structure_block: struct {
            location: Position,
            action: Enum(VarU7, enum(u7) {
                update_data = 0,
                save_structure = 1,
                load_structure = 2,
                detect_size = 3,
            }),
            mode: Enum(VarU7, enum(u7) {
                save = 0,
                load = 1,
                corner = 2,
                data = 3,
            }),
            name: PString(32767),
            offset: V3(i8),
            size: V3(i8),
            mirror: Enum(VarU7, enum(u7) {
                none = 0,
                left_right = 1,
                front_back = 2,
            }),
            rotation: Enum(VarU7, enum(u7) {
                none = 0,
                clockwise_90 = 1,
                clockwise_180 = 2,
                counterclockwise_90 = 3,
            }),
            metadata: PString(128),
            integrity: f32,
            seed: VarI64,
            flags: packed struct(u8) {
                ignore_entities: bool,
                show_air: bool,
                show_bounding_box: bool,
                _u: u5 = 0,
            },
        },
        update_sign: struct {
            location: Position,
            is_front_text: bool,
            lines: [4]PString(384),
        },
        swing_arm: struct {
            hand: Hand,
        },
        teleport_to_entity: struct {
            uuid: Uuid,
        },
        use_item_on: struct {
            hand: Hand,
            location: Position,
            face: Enum(VarU7, enum(u7) {
                bottom = 0,
                top = 1,
                north = 2,
                south = 3,
                west = 4,
                east = 5,
            }),
            cursor_position: V3(f32),
            inside_block: bool,
            sequence: VarI32,
        },
        use_item: struct {
            hand: Hand,
            sequence: VarI32,
        },
    });
};
