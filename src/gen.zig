const std = @import("std");
const mem = std.mem;
const math = std.math;
const json = std.json;
const path = std.fs.path;
const Allocator = mem.Allocator;

fn readFileData(a: Allocator, fname: []const u8) ![]const u8 {
    var data = std.ArrayList(u8).init(a);
    defer data.deinit();
    var inf = std.fs.cwd().openFile(fname, .{}) catch |e| {
        std.debug.print("Failed to find file \"{s}\", {any}\n", .{ fname, e });
        return e;
    };
    defer inf.close();
    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 512 }).init();
    try fifo.pump(inf.reader(), data.writer());
    return try data.toOwnedSlice();
}

fn writeCamelToSnake(writer: anytype, text: []const u8) !void {
    for (text, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i != 0) {
                try writer.writeByte('_');
            }
            try writer.writeByte(std.ascii.toLower(c));
        } else {
            try writer.writeByte(c);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);

    const MinecraftVersion = "1.20.4";
    const minecraft_data_path = args[1];
    const out_fname = args[2];
    const datapaths_path = try path.join(a, &.{
        minecraft_data_path,
        "dataPaths.json",
    });
    defer a.free(datapaths_path);

    const datapaths_data = try readFileData(a, datapaths_path);
    defer a.free(datapaths_data);
    var datapaths_json = try json.parseFromSlice(json.Value, a, datapaths_data, .{});
    defer datapaths_json.deinit();

    var datapaths_obj =
        datapaths_json.value.object.get("pc").?.object.get(MinecraftVersion).?.object;
    const blocks_path = try path.join(a, &.{
        minecraft_data_path,
        datapaths_obj.get("blocks").?.string,
        "blocks.json",
    });
    defer a.free(blocks_path);
    const biomes_path = try path.join(a, &.{
        minecraft_data_path,
        datapaths_obj.get("biomes").?.string,
        "biomes.json",
    });
    defer a.free(biomes_path);
    const effects_path = try path.join(a, &.{
        minecraft_data_path,
        datapaths_obj.get("effects").?.string,
        "effects.json",
    });
    defer a.free(effects_path);

    const blocks_data = try readFileData(a, blocks_path);
    defer a.free(blocks_data);

    var blocks_json = try json.parseFromSlice([]const struct {
        id: usize,
        name: []const u8,
        displayName: []const u8,
        hardness: f64,
        resistance: f64,
        stackSize: usize,
        diggable: bool,
        material: []const u8,
        transparent: bool,
        emitLight: usize,
        filterLight: usize,
        defaultState: usize,
        minStateId: usize,
        maxStateId: usize,
        states: []const struct {
            name: []const u8,
            type: enum {
                @"enum",
                int,
                bool,
            },
            num_values: usize,
            values: ?[]const []const u8 = null,
        },
        drops: []const usize,
        boundingBox: enum {
            empty,
            block,
        },
        harvestTools: ?json.Value = null,
    }, a, blocks_data, .{ .ignore_unknown_fields = true });
    defer blocks_json.deinit();

    const biomes_data = try readFileData(a, biomes_path);
    defer a.free(biomes_data);

    var biomes_json = try json.parseFromSlice([]const struct {
        id: usize,
        name: []const u8,
        category: []const u8,
        temperature: f64,
        precipitation: ?[]const u8 = null,
        has_precipitation: ?bool = null,
        dimension: enum {
            overworld,
            nether,
            end,
        },
        displayName: []const u8,
        color: usize,
        rainfall: ?f64 = null,
    }, a, biomes_data, .{});
    defer biomes_json.deinit();

    const effects_data = try readFileData(a, effects_path);
    defer a.free(effects_data);

    const effects_json = try json.parseFromSlice([]const struct {
        id: usize,
        displayName: []const u8,
        name: []const u8,
        type: enum { good, bad },
    }, a, effects_data, .{});
    defer effects_json.deinit();

    var outf = (if (std.mem.startsWith(u8, out_fname, "/"))
        std.fs.createFileAbsolute(out_fname, .{})
    else
        std.fs.cwd().createFile(out_fname, .{})) catch |e| {
        std.debug.print("Failed to create file \"{s}\", {any}\n", .{ out_fname, e });
        return e;
    };
    defer outf.close();
    var bw = std.io.bufferedWriter(outf.writer());
    defer bw.flush() catch {};
    var w = bw.writer();

    try w.writeAll(
        \\const std = @import("std");
        \\
        \\pub const Block = enum(Id) {
        \\
    );
    const blroot = blocks_json.value;
    var max_block_id: usize = 0;
    for (blroot) |v| {
        if (v.id > max_block_id) max_block_id = v.id;

        try w.print("    {s} = {},\n", .{ v.name, v.id });
    }
    try w.print("\n    pub const MaxId = {};\n", .{max_block_id});
    try w.print(
        "    pub const Id = u{};\n",
        .{std.math.log2_int_ceil(usize, max_block_id + 1)},
    );
    try w.writeAll(
        \\    
        \\    pub fn displayName(self: @This()) [:0]const u8 {
        \\        return switch (self) {
        \\
    );
    for (blroot) |v| {
        try w.print("            .{s} => \"{s}\",\n", .{ v.name, v.displayName });
    }
    try w.writeAll(
        \\        };
        \\    }
        \\    
        \\    pub fn defaultStateId(self: @This()) BlockState.Id {
        \\        return switch (self) {
        \\
    );
    for (blroot) |v| {
        try w.print(" " ** 12 ++ ".{s} => {},\n", .{ v.name, v.defaultState });
    }
    try w.writeAll(
        \\        };
        \\    }
        \\};
        \\
        \\pub const BlockState = union(Block) {
        \\
    );
    var max_state_id: usize = 0;
    for (blroot) |v| {
        if (v.maxStateId > max_state_id) max_state_id = v.maxStateId;

        if (v.states.len == 0) {
            try w.print("    {s}: void,\n", .{v.name});
        } else {
            try w.print("    {s}: struct {{\n", .{v.name});
            for (v.states) |sv| {
                switch (sv.type) {
                    .int => {
                        const state_first_value =
                            try std.fmt.parseInt(usize, sv.values.?[0], 10);
                        const bitwidth = std.math.log2_int_ceil(u64, @intCast(
                            sv.num_values + state_first_value,
                        ));
                        try w.print("        {s}: u{},\n", .{ sv.name, bitwidth });
                    },
                    .bool => {
                        try w.print("        {s}: bool,\n", .{sv.name});
                    },
                    .@"enum" => {
                        try w.print("        {s}: enum {{\n", .{sv.name});
                        for (sv.values.?) |ev| {
                            try w.print("            {s},\n", .{ev});
                        }
                        try w.print("        }},\n", .{});
                    },
                }
            }
            try w.print("    }},\n", .{});
        }
    }
    try w.print(
        \\    pub const MaxId = {};
        \\    pub const Id = u{};
        \\
    , .{ max_state_id, std.math.log2_int_ceil(u64, max_state_id + 1) });
    try w.writeAll(
        \\    const fields = @typeInfo(@This()).Union.fields;
        \\
        \\    pub fn fromId(id_: Id) ?@This() {
        \\        var id: Id = id_;
        \\        return switch (id) {
        \\
    );
    for (blroot, 0..) |v, i| {
        if (v.states.len == 0) {
            try w.print(" " ** 12 ++ "{} => .{s},\n", .{ v.minStateId, v.name });
        } else {
            try w.print(
                " " ** 12 ++ "{}...{} => {{\n" ++ (" " ** 16) ++ "id -= {};\n",
                .{ v.minStateId, v.maxStateId, v.minStateId },
            );
            for (v.states) |sv| if (sv.type == .@"enum") {
                try w.print(
                    " " ** 16 ++
                        "const sfields = @typeInfo(fields[{}].type).Struct.fields;\n",
                    .{i},
                );
                break;
            };
            var si = v.states.len;
            while (si > 0) {
                si -= 1;
                const sv = v.states[si];
                try w.print(" " ** 16 ++ "const @\"{s}\" = ", .{sv.name});
                switch (sv.type) {
                    .int => {
                        const state_first_value =
                            try std.fmt.parseInt(usize, sv.values.?[0], 10);
                        try w.print(
                            "id % {} + {};\n" ++ (" " ** 16) ++ "id /= {};\n",
                            .{ sv.values.?.len, state_first_value, sv.values.?.len },
                        );
                    },
                    .bool => {
                        try w.print(
                            "(id % 2) == 0;\n" ++ (" " ** 16) ++ "id /= 2;\n",
                            .{},
                        );
                    },
                    .@"enum" => {
                        try w.print(
                            "@as(sfields[{}].type, @enumFromInt(id % {}));\n" ++
                                (" " ** 16) ++ "id /= {};\n",
                            .{ si, sv.values.?.len, sv.values.?.len },
                        );
                    },
                }
            }
            try w.print(" " ** 16 ++ "return .{{ .{s} = .{{\n", .{v.name});
            for (v.states) |sv| {
                switch (sv.type) {
                    .int => {
                        try w.print(
                            " " ** 20 ++ ".{s} = @intCast(@\"{s}\"),\n",
                            .{ sv.name, sv.name },
                        );
                    },
                    else => {
                        try w.print(
                            " " ** 20 ++ ".{s} = @\"{s}\",\n",
                            .{ sv.name, sv.name },
                        );
                    },
                }
            }
            try w.print(" " ** 16 ++ "}} }};\n", .{});
            try w.print(" " ** 12 ++ "}},\n", .{});
        }
    }

    try w.writeAll(
        \\            else => null,
        \\        };
        \\    }
        \\    
        \\    pub fn toId(self: BlockState) Id {
        \\        return switch (self) {
        \\
    );
    for (blroot) |v| {
        if (v.states.len == 0) {
            try w.print(" " ** 12 ++ ".{s} => {},\n", .{ v.name, v.minStateId });
        } else {
            try w.print(
                " " ** 12 ++ ".{s} => |d| {{\n" ++ (" " ** 16) ++ "var id: Id = {};\n",
                .{ v.name, v.minStateId },
            );
            for (v.states, 0..) |sv, si| {
                const last = si == v.states.len - 1;
                switch (sv.type) {
                    .int => {
                        const state_first_value =
                            try std.fmt.parseInt(usize, sv.values.?[0], 10);
                        if (state_first_value != 0) {
                            try w.print(
                                " " ** 16 ++ "id += d.{s} - {};\n",
                                .{ sv.name, state_first_value },
                            );
                        } else {
                            try w.print(
                                " " ** 16 ++ "id += d.{s};\n",
                                .{sv.name},
                            );
                        }
                        if (!last) {
                            try w.print(" " ** 16 ++ "id *= {};\n", .{sv.values.?.len});
                        }
                    },
                    .bool => {
                        try w.print(
                            " " ** 16 ++ "id += @intFromBool(!d.{s});\n",
                            .{sv.name},
                        );
                        if (!last) try w.print(" " ** 16 ++ "id *= {};\n", .{2});
                    },
                    .@"enum" => {
                        try w.print(
                            " " ** 16 ++ "id += @intFromEnum(d.{s});\n",
                            .{sv.name},
                        );
                        if (!last) {
                            try w.print(" " ** 16 ++ "id *= {};\n", .{sv.values.?.len});
                        }
                    },
                }
            }
            try w.writeAll(" " ** 16 ++ "return id;\n");
            try w.print(" " ** 12 ++ "}},\n", .{});
        }
    }
    try w.writeAll(
        \\        };
        \\    }
        \\};
        \\
        \\pub const Dimension = enum { overworld, nether, end };
        \\
        \\pub const Biome = enum(Id) {
        \\
    );

    const biroot = biomes_json.value;
    var max_biome_id: usize = 0;
    var category_set = std.BufSet.init(a);
    defer category_set.deinit();
    for (biroot) |v| {
        if (v.id > max_biome_id) max_biome_id = v.id;
        try w.print(" " ** 4 ++ "{s} = {},\n", .{ v.name, v.id });
        try category_set.insert(v.category);
    }
    try w.print(
        "\n" ++ (" " ** 4) ++ "pub const Id = u{};\n",
        .{math.log2_int_ceil(usize, max_biome_id + 1)},
    );
    try w.writeAll(
        \\    
        \\    pub fn displayName(self: Biome) [:0]const u8 {
        \\        return switch(self) {
        \\
    );
    for (biroot) |v| {
        try w.print(" " ** 12 ++ ".{s} => \"{s}\",\n", .{ v.name, v.displayName });
    }
    try w.writeAll(
        \\        };
        \\    }
        \\    
        \\    pub fn dimension(self: Biome) Dimension {
        \\        return switch(self) {
        \\
    );
    inline for (.{ .overworld, .nether, .end }) |dim| {
        for (biroot) |v| if (v.dimension == dim) {
            try w.print(" " ** 12 ++ ".{s},\n", .{v.name});
        };
        try w.print(" " ** 12 ++ "=> .{s},\n\n", .{@tagName(dim)});
    }
    try w.writeAll(
        \\        };
        \\    }
        \\    
        \\    pub const Category = enum {
        \\
    );
    var biome_category_iter = category_set.iterator();
    while (biome_category_iter.next()) |category| {
        try w.print(" " ** 8 ++ "{s},\n", .{category.*});
    }
    try w.writeAll(
        \\    };
        \\    
        \\    pub fn category(self: Biome) Category {
        \\        return switch(self) {
        \\
    );
    biome_category_iter = category_set.iterator();
    while (biome_category_iter.next()) |category| {
        for (biroot) |v| if (mem.eql(u8, v.category, category.*)) {
            try w.print(" " ** 12 ++ ".{s},\n", .{v.name});
        };
        try w.print(" " ** 12 ++ "=> .{s},\n\n", .{category.*});
    }
    const efroot = effects_json.value;
    var max_effect_id: usize = 0;
    try w.writeAll(
        \\        };
        \\    }
        \\};
        \\
        \\pub const Effect = enum(Id) {
        \\
    );
    for (efroot) |v| {
        if (v.id > max_effect_id) max_effect_id = v.id;
        try w.writeAll(" " ** 4);
        try writeCamelToSnake(w, v.name);
        try w.print(" = {},\n", .{v.id});
    }
    try w.print(
        "\n" ++ (" " ** 4) ++ "pub const Id = u{};\n",
        .{math.log2_int_ceil(usize, max_effect_id + 1)},
    );
    try w.writeAll(
        \\    
        \\    pub fn displayName(self: Effect) [:0]const u8 {
        \\        return switch(self) {
        \\
    );
    for (efroot) |v| {
        try w.writeAll(" " ** 12 ++ ".");
        try writeCamelToSnake(w, v.name);
        try w.print(" => \"{s}\",\n", .{v.displayName});
    }
    try w.writeAll(
        \\        };
        \\    }
        \\    
        \\    pub const Kind = enum { good, bad };
        \\    pub fn kind(self: Effect) Kind {
        \\        return switch(self) {
        \\
    );
    inline for (.{ .good, .bad }) |kind| {
        for (efroot) |v| if (v.type == kind) {
            try w.writeAll(" " ** 12 ++ ".");
            try writeCamelToSnake(w, v.name);
            try w.writeAll(",\n");
        };
        try w.print(" " ** 12 ++ "=> .{s},\n\n", .{@tagName(kind)});
    }
    try w.writeAll(
        \\        };
        \\    }
        \\};
        \\
    );
}
