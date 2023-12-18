// this is probably like the 6th time im reimplementing nbt in zig. oh well

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

const serde = @import("serde.zig");

pub fn isString(comptime T: type) bool {
    return switch (T) {
        []const u8, []u8 => true,
        else => false,
    };
}

pub const Tag = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
    int_array = 11,
    long_array = 12,

    pub const E = error{InvalidTag};
    pub fn fromInt(val: anytype) E!Tag {
        errdefer std.debug.print("\ngot val {}\n", .{val});
        if (val >= 0 and val <= 12)
            return @enumFromInt(val)
        else
            return error.InvalidTag;
    }

    pub fn toString(tag: Tag) [:0]const u8 {
        return switch (tag) {
            .end => "TAG_End",
            .byte => "TAG_Byte",
            .short => "TAG_Short",
            .int => "TAG_Int",
            .long => "TAG_Long",
            .float => "TAG_Float",
            .double => "TAG_Double",
            .byte_array => "TAG_ByteArray",
            .string => "TAG_String",
            .list => "TAG_List",
            .compound => "TAG_Compound",
            .int_array => "TAG_IntArray",
            .long_array => "TAG_LongArray",
        };
    }
};

pub const NamedTag = struct {
    tag: Tag,
    name: []const u8,

    pub const ST = serde.PrefixedArray(u16, u8, .{});
    pub const UT = @This();
    pub const E = ST.E || Tag.E || error{EndOfStream};

    pub fn write(writer: anytype, in: UT) !void {
        try writer.writeByte(@intFromEnum(in.tag));
        if (in.tag != .end) {
            try ST.write(writer, in.name);
        }
    }
    pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
        const tag = try Tag.fromInt(try reader.readByte());
        var name: []const u8 = "";
        if (tag != .end)
            try ST.read(reader, &name, a);
        out.* = .{
            .tag = tag,
            .name = name,
        };
    }
    pub fn deinit(self: *UT, a: Allocator) void {
        ST.deinit(&self.name, a);
        self.* = undefined;
    }
    pub fn size(self: UT) usize {
        return 1 + if (self.tag == .end) 0 else ST.size(self.name);
    }

    pub fn getTag(self: UT) Tag {
        return self.tag;
    }
};

pub fn WithName(comptime name: []const u8, comptime T: type) type {
    return struct {
        pub const Name = name;
        pub usingnamespace Spec(T);
    };
}

pub fn Compound(comptime T: type) type {
    return struct {
        pub const specs = serde.StructSpecs(Spec, T);
        pub const UT = serde.StructUT(T, &specs);
        const utinfo = @typeInfo(UT).Struct;
        pub const E = serde.SpecsError(&specs) || NamedTag.E || error{
            DuplicateField,
            UnexpectedField,
            InvalidTag,
            MissingFields,
        };

        pub fn write(writer: anytype, in: UT) !void {
            inline for (utinfo.fields, 0..) |field, i| blk: {
                if (@typeInfo(field.type) == .Optional) {
                    if (@field(in, field.name) == null) break :blk;
                }
                const d = if (@typeInfo(field.type) == .Optional)
                    @field(in, field.name).?
                else
                    @field(in, field.name);
                try NamedTag.write(writer, .{
                    .tag = specs[i].getTag(d),
                    .name = if (@hasDecl(specs[i], "Name"))
                        specs[i].Name
                    else
                        field.name,
                });
                try specs[i].write(writer, d);
            }
            try writer.writeByte(@intFromEnum(Tag.end));
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            var written = std.StaticBitSet(specs.len).initEmpty();
            var must_write = comptime blk: {
                var s = std.StaticBitSet(specs.len).initEmpty();
                for (utinfo.fields, 0..) |field, i| {
                    if (@typeInfo(field.type) == .Optional) s.set(i);
                }
                break :blk s;
            };
            inline for (utinfo.fields) |field| {
                if (@typeInfo(field.type) == .Optional)
                    @field(out, field.name) = null;
            }
            errdefer {
                comptime var i = specs.len;
                inline while (i > 0) {
                    i -= 1;
                    if (written.isSet(i)) {
                        if (@typeInfo(utinfo.fields[i].type) == .Optional) {
                            if (@field(out, utinfo.fields[i].name)) |*d|
                                specs[i].deinit(d, a);
                        } else {
                            specs[i].deinit(&@field(out, utinfo.fields[i].name), a);
                        }
                    }
                }
            }
            blk: while (true) {
                var named_tag: NamedTag = undefined;
                try NamedTag.read(reader, &named_tag, a);
                defer NamedTag.deinit(&named_tag, a);
                if (named_tag.tag == .end) {
                    if (must_write.count() < specs.len) {
                        //inline for (utinfo.fields, 0..) |field, i| {
                        //    if (!must_write.isSet(i)) {
                        //        std.debug.print("missing {s}\n", .{field.name});
                        //    }
                        //}
                        return error.MissingFields;
                    } else {
                        break;
                    }
                }
                //std.debug.print("read compound field \"{s}\"\n", .{named_tag.name});
                inline for (utinfo.fields, specs, 0..) |field, spec, i| {
                    const name = if (@hasDecl(spec, "Name")) spec.Name else field.name;
                    if (mem.eql(u8, name, named_tag.name)) {
                        if (written.isSet(i)) return error.DuplicateField;
                        const d: *spec.UT =
                            if (@typeInfo(field.type) == .Optional)
                        iblk: {
                            // TODO: pointer optionals mess this up :( figure out the
                            //     other places where its messed up
                            if (@typeInfo(spec.UT) == .Pointer)
                                break :iblk @as(*spec.UT, @ptrCast(&@field(out, field.name)));
                            @field(out, field.name) = @as(spec.UT, undefined);
                            break :iblk &@field(out, field.name).?;
                        } else &@field(out, field.name);

                        if (@hasDecl(spec, "NbtTag")) {
                            if (named_tag.tag != spec.NbtTag) {
                                return error.InvalidTag;
                            }
                            try spec.read(reader, d, a);
                        } else {
                            try spec.read(reader, d, a, named_tag.tag);
                        }
                        written.set(i);
                        must_write.set(i);
                        continue :blk;
                    }
                }
                return error.UnexpectedField;
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            comptime var i = specs.len;
            inline while (i > 0) {
                i -= 1;
                if (@typeInfo(utinfo.fields[i].type) == .Optional) {
                    if (@field(self, utinfo.fields[i].name)) |*d|
                        specs[i].deinit(d, a);
                } else {
                    specs[i].deinit(&@field(self, utinfo.fields[i].name), a);
                }
            }
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            var total: usize = 1;
            inline for (utinfo.fields, 0..) |field, i| blk: {
                if (@typeInfo(field.type) == .Optional) {
                    if (@field(self, field.name) == null) break :blk;
                }
                const d = if (@typeInfo(field.type) == .Optional)
                    @field(self, field.name).?
                else
                    @field(self, field.name);
                total += NamedTag.size(.{
                    .tag = specs[i].getTag(d),
                    .name = if (@hasDecl(specs[i], "Name"))
                        specs[i].Name
                    else
                        field.name,
                }) + specs[i].size(d);
            }
            return total;
        }
        pub const NbtTag = Tag.compound;
        pub fn getTag(_: UT) Tag {
            return NbtTag;
        }
    };
}

pub fn List(comptime T: type) type {
    return struct {
        const tag = tagFromType(T);
        pub const LenSpec = serde.Casted(serde.Num(i32, .big), usize);
        pub const InnerSpec = Spec(T);
        pub const UT = []const InnerSpec.UT;
        pub const E = InnerSpec.E || LenSpec.E || Tag.E || error{
            EndOfStream,
            InvalidTag,
        };
        pub fn write(writer: anytype, in: UT) !void {
            try writer.writeByte(@intFromEnum(tag));
            try LenSpec.write(writer, in.len);
            for (in) |item| try InnerSpec.write(writer, item);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            if ((try Tag.fromInt(try reader.readByte())) != tag)
                return error.InvalidTag;
            var len: usize = undefined;
            try LenSpec.read(reader, &len, undefined);
            var arr = try a.alloc(InnerSpec.UT, len);
            errdefer a.free(arr);

            for (arr, 0..) |*item, i| {
                errdefer {
                    var j = i;
                    while (j > 0) {
                        j -= 1;
                        InnerSpec.deinit(&arr[j], a);
                    }
                }
                if (@hasDecl(InnerSpec, "NbtTag")) {
                    try InnerSpec.read(reader, item, a);
                } else {
                    if (@typeInfo(@TypeOf(InnerSpec.read)).Fn.params.len != 4) {
                        @compileError(
                            "invalid type \"" ++
                                @typeName(InnerSpec) ++
                                "\", not an nbt type? (parent type: \"" ++
                                @typeName(@This()) ++
                                "\")",
                        );
                    }
                    try InnerSpec.read(reader, item, a, tag);
                }
            }
            out.* = arr;
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                InnerSpec.deinit(@constCast(&self.*[i]), a);
            }
            a.free(self.*);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            var total = 1 + LenSpec.size(self.len);
            for (self) |item| total += InnerSpec.size(item);
            return total;
        }
        pub const NbtTag = Tag.list;
        pub fn getTag(_: UT) Tag {
            return NbtTag;
        }
    };
}

pub fn tagFromType(comptime T: type) Tag {
    switch (@typeInfo(T)) {
        .Struct => return if (@hasDecl(T, "NbtTag"))
            T.NbtTag
        else
            .compound,
        .Bool => return .byte,
        .Int => |info| if (info.signedness == .signed) switch (info.bits) {
            8 => return .byte,
            16 => return .short,
            32 => return .int,
            64 => return .long,
            else => {},
        },
        .Float => |info| switch (info.bits) {
            32 => return .float,
            64 => return .double,
            else => {},
        },
        .Pointer => |info| {
            if (isString(T)) {
                return .string;
            }
            const child_info = @typeInfo(info.child);
            if (child_info == .Int) {
                switch (child_info.Int.bits) {
                    8 => return .byte_array,
                    32 => return .int_array,
                    64 => return .long_array,
                    else => unreachable,
                }
            } else {
                return .list;
            }
        },
        else => {},
    }
    @compileError("cant find tag from type " ++ @typeName(T));
}
pub fn typeFromTag(comptime tag: Tag) type {
    return switch (tag) {
        .end => void,
        .byte => i8,
        .short => i16,
        .int => i32,
        .long => i64,
        .float => f32,
        .double => f64,
        .byte_array => []i8,
        .int_array => []i32,
        .long_array => []i64,
        .string => []u8,
        .list => []DynamicValue.UT, // hmm
        .compound => []DynamicCompound.KV,
    };
}

pub fn Wrap(comptime ST: type, comptime tag: Tag) type {
    return struct {
        pub usingnamespace ST;
        pub const NbtTag = tag;
        pub fn getTag(_: ST.UT) Tag {
            return tag;
        }
    };
}

pub fn Optional(comptime T: type) type {
    return struct {
        pub const IsOptional = {};
        pub usingnamespace Spec(T);
    };
}

pub fn Num(comptime T: type) type {
    return Wrap(serde.Num(T, .big), tagFromType(T));
}
pub const Bool = Wrap(serde.Bool, .byte);
pub const String = Wrap(serde.PrefixedArray(u16, u8, .{}), .string);
pub fn TypedList(comptime T: type) type {
    return Wrap(
        serde.PrefixedArray(serde.Num(i32, .big), @typeInfo(T).Pointer.child, .{}),
        tagFromType(T),
    );
}
// TODO: we can make this not allocate
pub fn StringEnum(comptime vals: type) type {
    return Wrap(serde.StringEnum(vals, String), .string);
}

pub const DynamicValue = union(Tag) {
    end: void,
    byte: i8,
    short: i16,
    int: i32,
    long: i64,
    float: f32,
    double: f64,
    byte_array: []const i8,
    string: []const u8,
    list: []const DynamicValue.UT,
    compound: DynamicCompound.UT,
    int_array: []const i32,
    long_array: []const i64,

    pub const UT = @This();
    pub const E = NamedTag.E || Tag.E || error{ EndOfStream, TooDeep, InvalidLength };
    pub fn write(
        writer: anytype,
        in: UT,
        depth: u32,
    ) (@TypeOf(writer).Error || E)!void {
        if (depth == 0) return error.TooDeep;
        switch (in) {
            .end => {},
            inline .byte, .short, .int, .long, .float, .double => |d| {
                try Num(@TypeOf(d)).write(writer, d);
            },
            inline .byte_array, .int_array, .long_array => |d| {
                try serde.PrefixedArray(
                    Num(i32),
                    Num(@typeInfo(@TypeOf(d)).Pointer.child),
                    .{},
                ).write(writer, d);
            },
            .list => |d| {
                try writer.writeByte(
                    @intFromEnum(if (d.len == 0) .end else @as(Tag, d[0])),
                );
                try Num(i32).write(writer, @intCast(d.len));
                for (d) |b| try DynamicValue.write(writer, b, depth - 1);
            },
            .string => |d| {
                try serde.PrefixedArray(u16, u8, .{}).write(writer, d);
            },
            .compound => |d| try DynamicCompound.write(writer, d, depth),
        }
    }
    pub fn read(
        reader: anytype,
        out: *UT,
        a: Allocator,
        tag: Tag,
        depth: u32,
    ) (@TypeOf(reader).Error || Allocator.Error || E)!void {
        if (depth == 0) return error.TooDeep;
        switch (tag) {
            .end => out.* = .end,
            inline .byte, .short, .int, .long, .float, .double => |v| {
                out.* = @unionInit(DynamicValue, @tagName(v), undefined);
                try Num(typeFromTag(v)).read(reader, &@field(out, @tagName(v)), a);
            },
            inline .byte_array, .int_array, .long_array => |v| {
                out.* = @unionInit(DynamicValue, @tagName(v), undefined);
                try serde.PrefixedArray(
                    Num(i32),
                    Num(@typeInfo(typeFromTag(v)).Pointer.child),
                    .{},
                ).read(reader, &@field(out, @tagName(v)), a);
            },
            .string => {
                out.* = .{ .string = undefined };
                try serde.PrefixedArray(u16, u8, .{}).read(reader, &out.string, a);
            },
            .list => {
                const inner_tag = try Tag.fromInt(try reader.readByte());
                var len_: i32 = undefined;
                try Num(i32).read(reader, &len_, a);
                const len = std.math.cast(usize, len_) orelse
                    return error.InvalidLength;
                var data = try a.alloc(DynamicValue, len);
                errdefer a.free(data);
                for (data, 0..) |*item, i| {
                    errdefer {
                        var j = i;
                        while (j > 0) {
                            j -= 1;
                            DynamicValue.deinit(&data[j], a);
                        }
                    }
                    try DynamicValue.read(reader, item, a, inner_tag, depth - 1);
                }
                out.* = .{ .list = data };
            },
            .compound => {
                out.* = .{ .compound = undefined };
                try DynamicCompound.read(reader, &out.compound, a, depth);
            },
        }
    }
    pub fn deinit(self: *UT, a: Allocator) void {
        switch (self.*) {
            .end, .byte, .short, .int, .long, .float, .double => {},
            inline .byte_array, .int_array, .long_array, .string => |d| a.free(d),
            .list => |d| {
                var i = d.len;
                while (i > 0) {
                    i -= 1;
                    DynamicValue.deinit(@constCast(&d[i]), a);
                }
                a.free(d);
            },
            .compound => |*d| DynamicCompound.deinit(d, a),
        }
        self.* = undefined;
    }
    pub fn size(self: UT) usize {
        switch (self) {
            inline .end, .byte, .short, .int, .long, .float, .double => |d| {
                return @sizeOf(@TypeOf(d));
            },
            inline .byte_array, .int_array, .long_array => |d| {
                return @sizeOf(i32) +
                    (@sizeOf(@typeInfo(@TypeOf(d)).Pointer.child) * d.len);
            },
            .string => |d| return @sizeOf(u16) + d.len,
            .list => |d| {
                var total: usize = @sizeOf(i32) + 1;
                for (d) |item| total += DynamicValue.size(item);
                return total;
            },
            .compound => |d| return DynamicCompound.size(d),
        }
    }
    pub fn getTag(self: UT) Tag {
        return self;
    }

    fn dpthIdt(writer: anytype, depth: u32) !void {
        try writer.writeByteNTimes(' ', depth * 2);
    }
    pub fn print(
        self: UT,
        name: ?[]const u8,
        writer: anytype,
        depth: u32,
    ) @TypeOf(writer).Error!void {
        try dpthIdt(writer, depth);
        try writer.writeAll(DynamicValue.getTag(self).toString());
        if (name != null) {
            try writer.print("('{s}'): ", .{name.?});
        } else {
            try writer.writeAll("(None): ");
        }
        switch (self) {
            .end => {},
            inline .byte, .short, .int, .long, .float, .double => |d| {
                try writer.print("{d}\n", .{d});
            },
            inline .byte_array, .int_array, .long_array => |d| {
                try writer.print("{} entries\n", .{d.len});
                try dpthIdt(writer, depth);
                try writer.writeAll("{\n");
                //for (if (d.len > 20) d[0..20] else d) |item| {
                for (d) |item| {
                    try dpthIdt(writer, depth + 1);
                    try writer.print(
                        "{s}(None): {}\n",
                        .{ tagFromType(@TypeOf(item)).toString(), item },
                    );
                }
                //if (d.len > 20) {
                //    try dpthIdt(writer, depth + 1);
                //    try writer.writeAll("...\n");
                //}
                try dpthIdt(writer, depth);
                try writer.writeAll("}\n");
            },
            .string => |d| try writer.print("'{s}'\n", .{d}),
            .list => |d| {
                try writer.print("{} entries\n", .{d.len});
                try dpthIdt(writer, depth);
                try writer.writeAll("{\n");
                //for (if (d.len > 20) d[0..20] else d) |item| {
                for (d) |item| {
                    try DynamicValue.print(item, null, writer, depth + 1);
                }
                //if (d.len > 20) {
                //    try dpthIdt(writer, depth + 1);
                //    try writer.writeAll("...\n");
                //}
                try dpthIdt(writer, depth);
                try writer.writeAll("}\n");
            },
            .compound => |d| {
                try writer.print("{} entries\n", .{d.len});
                try dpthIdt(writer, depth);
                try writer.writeAll("{\n");
                for (d) |kv| {
                    try DynamicValue.print(kv.value, kv.name, writer, depth + 1);
                }
                try dpthIdt(writer, depth);
                try writer.writeAll("}\n");
            },
        }
    }
};

pub const DynamicCompound = struct {
    pub const KV = struct { name: []const u8, value: DynamicValue };
    pub const UT = []const KV;
    pub const E = DynamicValue.E;

    pub fn write(
        writer: anytype,
        in: UT,
        depth: u32,
    ) (@TypeOf(writer).Error || E)!void {
        assert(depth > 0);
        for (in) |kv| {
            try NamedTag.write(writer, .{ .tag = kv.value, .name = kv.name });
            try DynamicValue.write(writer, kv.value, depth - 1);
        }
        try NamedTag.write(writer, .{ .tag = .end, .name = "" });
    }
    pub fn read(
        reader: anytype,
        out: *UT,
        a: Allocator,
        depth: u32,
    ) (@TypeOf(reader).Error || Allocator.Error || E)!void {
        assert(depth > 0);
        var list = std.ArrayListUnmanaged(KV){};
        defer {
            var i = list.items.len;
            while (i > 0) {
                i -= 1;
                a.free(list.items[i].name);
                DynamicValue.deinit(&list.items[i].value, a);
            }
            list.deinit(a);
        }
        while (true) {
            var named_tag: NamedTag = undefined;
            try NamedTag.read(reader, &named_tag, a);
            if (named_tag.tag == .end) break;
            errdefer NamedTag.deinit(&named_tag, a);

            var item = try list.addOne(a);
            errdefer list.items.len -= 1;

            try DynamicValue.read(reader, &item.value, a, named_tag.tag, depth - 1);
            errdefer DynamicValue.deinit(&item, a);
            item.name = named_tag.name;
        }
        out.* = try list.toOwnedSlice(a);
    }
    pub fn deinit(self: *UT, a: Allocator) void {
        var i = self.len;
        while (i > 0) {
            i -= 1;
            a.free(self.*[i].name);
            DynamicValue.deinit(@constCast(&self.*[i].value), a);
        }
        a.free(self.*);
        self.* = undefined;
    }
    pub fn size(self: UT) usize {
        var total: usize = 1;
        for (self) |kv| total +=
            NamedTag.size(.{ .name = kv.name, .tag = kv.value }) +
            DynamicValue.size(kv.value);
        return total;
    }
    pub const NbtTag = Tag.compound;
    pub fn getTag(_: UT) Tag {
        return NbtTag;
    }
};

pub fn Dynamic(
    comptime kind: union(enum) { compound, tag: Tag, any },
    comptime MaxDepth: comptime_int,
) type {
    return if (kind == .compound) struct {
        pub const UT = DynamicCompound.UT;
        pub const E = DynamicCompound.E;
        pub fn write(writer: anytype, in: UT) !void {
            try DynamicCompound.write(writer, in, MaxDepth);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            try DynamicCompound.read(reader, out, a, MaxDepth);
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            DynamicCompound.deinit(self, a);
        }
        pub fn size(self: UT) usize {
            return DynamicCompound.size(self);
        }
        pub const NbtTag = Tag.compound;
        pub fn getTag(_: UT) Tag {
            return NbtTag;
        }
    } else if (kind == .tag) struct {
        pub const UT = DynamicValue.UT;
        pub const E = DynamicValue.E;
        pub fn write(writer: anytype, in: UT) !void {
            try DynamicValue.write(writer, in, MaxDepth);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            try DynamicValue.read(reader, out, a, kind.tag, MaxDepth);
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            DynamicValue.deinit(self, a);
        }
        pub fn size(self: UT) usize {
            return DynamicValue.size(self);
        }
        pub const NbtTag = kind.tag;
        pub fn getTag(_: UT) Tag {
            return NbtTag;
        }
    } else struct {
        pub const UT = DynamicValue.UT;
        pub const E = DynamicValue.E;
        pub fn write(writer: anytype, in: UT) !void {
            try DynamicValue.write(writer, in, MaxDepth);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator, tag: Tag) !void {
            try DynamicValue.read(reader, out, a, tag, MaxDepth);
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            DynamicValue.deinit(self, a);
        }
        pub fn size(self: UT) usize {
            return DynamicValue.size(self);
        }
        pub fn getTag(self: UT) Tag {
            return self;
        }
    };
}

pub fn Multiple(comptime T: type) type {
    return struct {
        const info = @typeInfo(T).Union;
        pub const specs = serde.StructSpecs(Spec, T);
        pub const UT = serde.StructUT(T, &specs);
        pub const E = serde.SpecsError(&specs) || error{InvalidTag};

        const EnumT = info.tag_type.?;
        const FieldEnumT = std.meta.FieldEnum(EnumT);
        fn tagI(comptime v: anytype) usize {
            return @intFromEnum(@field(FieldEnumT, @tagName(v)));
        }
        pub fn write(writer: anytype, in: UT) !void {
            switch (in) {
                inline else => |d, v| {
                    try specs[comptime tagI(v)].write(writer, d);
                },
            }
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator, tag: Tag) !void {
            switch (tag) {
                inline else => |v| if (@hasField(T, @tagName(v))) {
                    out.* = @unionInit(UT, @tagName(v), undefined);
                    try specs[comptime tagI(v)].read(
                        reader,
                        &@field(out, @tagName(v)),
                        a,
                    );
                    return;
                },
            }
            return error.InvalidTag;
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            switch (self.*) {
                inline else => |*d, v| {
                    specs[comptime tagI(v)].deinit(d, a);
                },
            }
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            switch (self) {
                inline else => |d, v| {
                    return specs[comptime tagI(v)].size(d);
                },
            }
        }
        pub fn getTag(self: UT) Tag {
            return switch (self) {
                inline else => |_, v| @field(Tag, @tagName(v)),
            };
        }
    };
}

pub fn Named(comptime name: ?[]const u8, comptime T: type) type {
    return struct {
        pub const InnerSpec = Spec(T);
        pub const UT = InnerSpec.UT;
        pub const E = InnerSpec.E ||
            NamedTag.E ||
            Tag.E ||
            error{ EndOfStream, InvalidTag, UnexpectedName };
        pub fn write(writer: anytype, in: UT) !void {
            if (name != null) {
                try NamedTag.write(writer, .{
                    .name = name.?,
                    .tag = InnerSpec.getTag(in),
                });
            } else {
                try writer.writeByte(@intFromEnum(InnerSpec.getTag(in)));
            }
            try InnerSpec.write(writer, in);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            const tag = blk: {
                if (name) |test_name| {
                    var named_tag: NamedTag = undefined;
                    try NamedTag.read(reader, &named_tag, a);
                    defer NamedTag.deinit(&named_tag, a);
                    if (!mem.eql(u8, test_name, named_tag.name))
                        return error.UnexpectedName;
                    break :blk named_tag.tag;
                } else {
                    break :blk try Tag.fromInt(try reader.readByte());
                }
            };
            if (@hasDecl(InnerSpec, "NbtTag")) {
                if (tag != InnerSpec.NbtTag) {
                    return error.InvalidTag;
                }
                try InnerSpec.read(reader, out, a);
            } else {
                try InnerSpec.read(reader, out, a, tag);
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            InnerSpec.deinit(self, a);
        }
        pub fn size(self: UT) usize {
            return InnerSpec.size(self) + if (name == null)
                1
            else
                NamedTag.size(.{
                    .name = name.?,
                    .tag = InnerSpec.getTag(self),
                });
        }
    };
}

/// nbt version of serde.zig's constant
pub fn Constant(
    comptime T: type,
    comptime value: Spec(T).UT,
    comptime eql: fn (Spec(T).UT, Spec(T).UT) bool,
) type {
    return struct {
        pub const InnerSpec = Spec(T);
        pub const UT = void;
        pub const E = InnerSpec.E || error{InvalidConstant};
        pub const NbtTag = InnerSpec.NbtTag;
        pub fn write(writer: anytype, _: UT) !void {
            try InnerSpec.write(writer, value);
        }
        pub fn read(reader: anytype, _: *UT, a: Allocator) !void {
            var out: InnerSpec.UT = undefined;
            try InnerSpec.read(reader, &out, a);
            defer InnerSpec.deinit(&out, a);
            if (!eql(value, out))
                return error.InvalidConstant;
        }
        pub fn deinit(_: *UT, _: Allocator) void {}
        pub fn size(_: UT) usize {
            return InnerSpec.size(value);
        }
        pub fn getTag(_: UT) Tag {
            return InnerSpec.getTag(value);
        }
    };
}

pub fn Spec(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Bool => Bool,
        .Pointer => |info| {
            if (isString(T))
                return String;
            const child_info = @typeInfo(info.child);
            if (child_info == .Int and child_info.Int.bits != 16)
                return TypedList(T);
            return List(info.child);
        },
        .Int, .Float => Num(T),
        .Optional => |info| Optional(Spec(info.child)),
        .Struct => {
            inline for (.{ "read", "write", "deinit", "size" }) |n| {
                if (!@hasDecl(T, n)) return Compound(T);
            }
            return T;
        },
        else => @compileError("type " ++ @typeName(T) ++ " not supported for nbt"),
    };
}

const testing = std.testing;

pub fn doDynamicTestOnValue(
    comptime ST: type,
    value: ST.UT,
    comptime named: bool,
    comptime check_allocations: bool,
) !void {
    var writebuf = std.ArrayList(u8).init(testing.allocator);
    defer writebuf.deinit();
    try ST.write(writebuf.writer(), value);

    var stream = std.io.fixedBufferStream(writebuf.items);
    var result: ST.UT = undefined;
    try ST.read(stream.reader(), &result, testing.allocator);
    defer ST.deinit(&result, testing.allocator);

    {
        errdefer std.debug.print("\ngot {any}\n", .{result});
        try testing.expectEqualDeep(value, result);
    }
    try testing.expectEqual(writebuf.items.len, ST.size(result));

    const DynamicST = if (named)
        Named(null, Dynamic(.any, @import("main.zig").MaxNbtDepth))
    else
        Dynamic(.compound, @import("main.zig").MaxNbtDepth);
    var dynamic_result: DynamicST.UT = undefined;
    stream = std.io.fixedBufferStream(writebuf.items);
    try DynamicST.read(stream.reader(), &dynamic_result, testing.allocator);
    defer DynamicST.deinit(&dynamic_result, testing.allocator);
    try testing.expectEqual(writebuf.items.len, DynamicST.size(dynamic_result));

    if (check_allocations) {
        testing.checkAllAllocationFailures(testing.allocator, (struct {
            pub fn read(allocator: Allocator, data: []const u8) !void {
                var stream_ = std.io.fixedBufferStream(data);
                var r: ST.UT = undefined;
                try ST.read(stream_.reader(), &r, allocator);
                ST.deinit(&r, allocator);
            }
        }).read, .{writebuf.items}) catch |e| {
            if (e != error.SwallowedOutOfMemoryError) return e;
        };
    }
}

test "named tags" {
    try serde.doTest(
        NamedTag,
        &.{ @intFromEnum(Tag.byte_array), 0, 4, 't', 'e', 's', 't' },
        .{
            .name = "test",
            .tag = .byte_array,
        },
        true,
    );
}

test "test.nbt" {
    try serde.doTest(
        Named("hello world", struct { name: []u8 }),
        &.{
            0x0a, 0x00, 0x0b, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x77, 0x6f,
            0x72, 0x6c, 0x64, 0x08, 0x00, 0x04, 0x6e, 0x61, 0x6d, 0x65, 0x00,
            0x09, 0x42, 0x61, 0x6e, 0x61, 0x6e, 0x72, 0x61, 0x6d, 0x61, 0x00,
        },
        .{ .name = "Bananrama" },
        true,
    );
}

test "bigtest.nbt, static" {
    // note: this is reordered according to layout in actual nbt file
    // other layouts will not work with the written output comparison
    const ST = Named("Level", struct {
        longTest: i64,
        shortTest: i16,
        stringTest: []u8,
        floatTest: f32,
        intTest: i32,
        nested: WithName("nested compound test", struct {
            ham: struct {
                name: []u8,
                value: f32,
            },
            egg: struct {
                name: []u8,
                value: f32,
            },
        }),
        listTest_long: WithName("listTest (long)", List(i64)),
        listTest_compound: WithName("listTest (compound)", []struct {
            name: []u8,
            created_on: WithName("created-on", i64),
        }),
        byteTest: i8,
        byteArrayTest: WithName(
            "byteArrayTest (the first 1000 values of (n*n*255+n*7)%100, " ++
                "starting with n=0 (0, 62, 34, 16, 8, ...))",
            []i8,
        ),
        doubleTest: f64,
    });
    const gzipbuf = @embedFile("test/bigtest.nbt");
    var gzipbufstream = std.io.fixedBufferStream(gzipbuf);
    var gzipstream = try std.compress.gzip.decompress(
        testing.allocator,
        gzipbufstream.reader(),
    );
    defer gzipstream.deinit();

    var buf_ = std.ArrayList(u8).init(testing.allocator);
    defer buf_.deinit();
    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 512 }).init();
    try fifo.pump(gzipstream.reader(), buf_.writer());
    const buf = buf_.items;

    var stream = std.io.fixedBufferStream(buf);

    var result: ST.UT = undefined;
    try ST.read(stream.reader(), &result, testing.allocator);
    defer ST.deinit(&result, testing.allocator);
    try testing.expectEqual(buf.len, ST.size(result));

    var writebuf = std.ArrayList(u8).init(testing.allocator);
    defer writebuf.deinit();
    try ST.write(writebuf.writer(), result);
    try testing.expectEqualSlices(u8, buf, writebuf.items);

    //std.debug.print("\nresult: {any}\n", .{result});

    try testing.expectEqual(@as(i32, 2147483647), result.intTest);
    try testing.expectEqualStrings("Eggbert", result.nested.egg.name);
    try testing.expectEqualStrings("Hampus", result.nested.ham.name);
    try testing.expect(std.math.approxEqAbs(
        f32,
        0.5,
        result.nested.egg.value,
        std.math.floatEps(f32) * 10,
    ));
    try testing.expect(std.math.approxEqAbs(
        f32,
        0.75,
        result.nested.ham.value,
        std.math.floatEps(f32) * 10,
    ));
    try testing.expect(std.math.approxEqAbs(
        f32,
        0.49823147058486938,
        result.floatTest,
        std.math.floatEps(f32) * 10,
    ));
    try testing.expect(std.math.approxEqAbs(
        f64,
        0.49312871321823148,
        result.doubleTest,
        std.math.floatEps(f64) * 10,
    ));
    try testing.expectEqualStrings(
        "HELLO WORLD THIS IS A TEST STRING \xc3\x85\xc3\x84\xc3\x96!",
        result.stringTest,
    ); // strings in bigtest.nbt are in utf8, not ascii
    try testing.expectEqual(@as(usize, 5), result.listTest_long.len);
    inline for (.{ 11, 12, 13, 14, 15 }, 0..) |item, i| {
        try testing.expectEqual(@as(i64, item), result.listTest_long[i]);
    }
    try testing.expectEqual(@as(i64, 9223372036854775807), result.longTest);
    try testing.expectEqual(@as(usize, 2), result.listTest_compound.len);
    inline for (.{
        .{ 1264099775885, "Compound tag #0" },
        .{ 1264099775885, "Compound tag #1" },
    }, 0..) |pair, i| {
        try testing.expectEqualStrings(pair[1], result.listTest_compound[i].name);
        try testing.expectEqual(
            @as(i64, pair[0]),
            result.listTest_compound[i].created_on,
        );
    }
    try testing.expectEqual(@as(usize, 1000), result.byteArrayTest.len);
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const expected: i8 = @intCast(@as(u8, @truncate((n * n * 255 + n * 7) % 100)));
        try testing.expectEqual(expected, result.byteArrayTest[n]);
    }
    try testing.expectEqual(@as(i16, 32767), result.shortTest);
}

test "bigtest.nbt, dynamic" {
    const gzipbuf = @embedFile("test/bigtest.nbt");
    var gzipbufstream = std.io.fixedBufferStream(gzipbuf);
    var gzipstream = try std.compress.gzip.decompress(
        testing.allocator,
        gzipbufstream.reader(),
    );
    defer gzipstream.deinit();

    var buf_ = std.ArrayList(u8).init(testing.allocator);
    defer buf_.deinit();
    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 512 }).init();
    try fifo.pump(gzipstream.reader(), buf_.writer());
    const buf = buf_.items;

    var stream = std.io.fixedBufferStream(buf);

    const ST = Named("Level", Dynamic(.any, 20));
    var result: ST.UT = undefined;
    try ST.read(stream.reader(), &result, testing.allocator);
    defer ST.deinit(&result, testing.allocator);

    var writebuf = std.ArrayList(u8).init(testing.allocator);
    defer writebuf.deinit();
    try ST.write(writebuf.writer(), result);
    try testing.expectEqualSlices(u8, buf, writebuf.items);

    //try DynamicValue.print(result, "Level", std.io.getStdErr().writer(), 0);
}
