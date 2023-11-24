const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const testing = std.testing;

pub fn Num(comptime T: type, comptime endian: std.builtin.Endian) type {
    const info = @typeInfo(T);
    if (info != .Int and info != .Float)
        @compileError("Expected an int or a float");
    if (info == .Int and (info.Int.bits % 8) != 0)
        @compileError(
            "Expected int width that is a multiple of 8, not " ++
                std.fmt.comptimePrint("{}", .{info.Int.bits}),
        );
    return struct {
        const U = @Type(.{ .Int = .{
            .signedness = .unsigned,
            .bits = if (info == .Float) info.Float.bits else info.Int.bits,
        } });

        pub const UT = T;
        pub const E = error{EndOfStream};

        pub fn write(writer: anytype, in: T) !void {
            try writer.writeInt(U, @bitCast(in), endian);
        }
        pub fn read(reader: anytype, out: *T, _: Allocator) !void {
            out.* = @bitCast(try reader.readInt(U, endian));
        }
        pub fn deinit(self: *T, _: Allocator) void {
            self.* = undefined;
        }
        pub fn size(_: T) usize {
            return @sizeOf(T);
        }
    };
}

pub const Bool = struct {
    pub const UT = bool;
    pub const E = error{EndOfStream};
    pub fn write(writer: anytype, in: bool) !void {
        try writer.writeByte(@intFromBool(in));
    }
    pub fn read(reader: anytype, out: *bool, _: Allocator) !void {
        out.* = (try reader.readByte()) != 0;
    }
    pub fn deinit(self: *bool, _: Allocator) void {
        self.* = undefined;
    }
    pub fn size(_: bool) usize {
        return 1;
    }
};

pub const Void = struct {
    pub const UT = void;
    pub const E = error{};
    pub fn write(_: anytype, _: void) !void {}
    pub fn read(_: anytype, _: *void, _: Allocator) !void {}
    pub fn deinit(_: *void, _: Allocator) void {}
    pub fn size(_: void) usize {
        return 0;
    }
};

/// also should work for union and enum
pub fn StructSpecs(
    comptime SpecFn: fn (comptime T_: type) type,
    comptime T: type,
) [std.meta.fields(T).len]type {
    const ifields = std.meta.fields(T);
    var specs: [ifields.len]type = undefined;
    inline for (&specs, ifields) |*spec, field| {
        spec.* = SpecFn(field.type);
    }
    return specs;
}

pub fn SpecsError(comptime specs: []const type) type {
    comptime var E = error{};
    inline for (specs) |spec| E = E || spec.E;
    return E;
}

pub fn BuiltinFieldType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Struct => std.builtin.Type.StructField,
        .Union => std.builtin.Type.UnionField,
        .Enum => std.builtin.Type.EnumField,
        else => unreachable,
    };
}
pub fn builtinField(from: anytype, comptime T: type) @TypeOf(from) {
    return switch (@TypeOf(from)) {
        std.builtin.Type.StructField => .{
            .name = from.name,
            .type = T,
            .default_value = if (@typeInfo(T) == .Optional)
                @as(?*const anyopaque, @ptrCast(&@as(T, null)))
            else
                null,
            .is_comptime = from.is_comptime,
            .alignment = @alignOf(T),
        },
        std.builtin.Type.UnionField => .{
            .name = from.name,
            .type = T,
            .alignment = @alignOf(T),
        },
        std.builtin.Type.EnumField => .{ .name = from.name },
        else => unreachable,
    };
}

/// also should work for union
pub fn StructUT(
    comptime T: type,
    comptime specs: []const type,
) type {
    const ifields = std.meta.fields(T);
    var fields: [ifields.len]BuiltinFieldType(T) = undefined;
    inline for (&fields, ifields, 0..) |*field, ifield, i| {
        field.* = builtinField(
            ifield,
            if (@typeInfo(T) == .Enum) void else specs[i].UT,
        );
    }
    return switch (@typeInfo(T)) {
        .Struct => @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } }),
        .Union => |info| @Type(.{ .Union = .{
            .layout = .Auto,
            .tag_type = info.tag_type,
            .fields = &fields,
            .decls = &.{},
        } }),
        .Enum => |info| @Type(.{ .Enum = .{
            .tag_type = info.tag_type,
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = info.is_exhaustive,
        } }),
        else => unreachable,
    };
}
pub fn Struct(comptime T: type) type {
    const info = @typeInfo(T).Struct;
    return struct {
        pub const specs = StructSpecs(Spec, T);
        pub const UT = StructUT(T, &specs);
        pub const E = SpecsError(&specs);

        pub fn write(writer: anytype, in: UT) !void {
            inline for (info.fields, 0..) |field, i| {
                try specs[i].write(writer, @field(in, field.name));
            }
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            inline for (info.fields, 0..) |field, i| {
                try specs[i].read(reader, &@field(out, field.name), a);
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            comptime var i = info.fields.len;
            inline while (i > 0) {
                i -= 1;
                specs[i].deinit(&@field(self, info.fields[i].name), a);
            }
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            var total: usize = 0;
            inline for (info.fields, 0..) |field, i| {
                total += specs[i].size(@field(self, field.name));
            }
            return total;
        }
    };
}

pub fn Enum(comptime I: type, comptime T: type) type {
    return struct {
        pub const TagSpec = Spec(I);
        pub const EnumI = @typeInfo(T).Enum.tag_type;
        pub const UT = T;
        pub const E = std.meta.IntToEnumError || TagSpec.E;

        pub inline fn getInt(self: T) TagSpec.UT {
            return @intCast(@intFromEnum(self));
        }

        pub fn write(writer: anytype, in: T) !void {
            try TagSpec.write(writer, getInt(in));
        }
        pub fn read(reader: anytype, out: *T, a: Allocator) !void {
            var n: TagSpec.UT = undefined;
            try TagSpec.read(reader, &n, a);
            defer TagSpec.deinit(&n, a);
            out.* = try std.meta.intToEnum(UT, @as(EnumI, @intCast(n)));
        }
        pub fn deinit(self: *T, _: Allocator) void {
            self.* = undefined;
        }
        pub fn size(self: T) usize {
            return TagSpec.size(getInt(self));
        }
    };
}

pub fn Union(comptime T: type) type {
    return struct {
        /// spec of T's enum
        pub const EnumT = @typeInfo(T).Union.tag_type.?;

        pub const specs = StructSpecs(Spec, T);
        pub const UT = StructUT(T, &specs);
        pub const E = SpecsError(&specs) || std.meta.IntToEnumError;
        pub const FieldEnumT = std.meta.FieldEnum(EnumT);
        pub const V = EnumT;

        fn tagI(v: EnumT) usize {
            return @intFromEnum(@field(FieldEnumT, @tagName(v)));
        }

        pub fn getValue(in: UT) V {
            return switch (in) {
                inline else => |_, v| @field(EnumT, @tagName(v)),
            };
        }

        pub fn write(writer: anytype, in: UT) !void {
            switch (in) {
                inline else => |d, v| {
                    try specs[comptime tagI(v)].write(writer, d);
                },
            }
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator, tag: EnumT) !void {
            switch (tag) {
                inline else => |v| {
                    out.* = @unionInit(UT, @tagName(v), undefined);
                    //@compileLog(@tagName(v));
                    try specs[comptime tagI(v)].read(
                        reader,
                        &@field(out, @tagName(v)),
                        a,
                    );
                },
            }
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
            return switch (self) {
                inline else => |d, v| specs[comptime tagI(v)].size(d),
            };
        }
    };
}

pub fn OptionalUnion(comptime T: type, comptime OtherT: type) type {
    return struct {
        pub const OptSpec = Spec(T);
        pub const OtherSpec = Spec(OtherT);

        pub const UT = union(Tag) {
            const Tag = enum(u1) { some, other };

            some: OptSpec.InnerSpec.UT,
            other: OtherSpec.UT,
        };
        pub const E = OptSpec.E || OtherSpec.E;

        pub fn write(writer: anytype, in: UT) !void {
            switch (in) {
                .some => |v| try OptSpec.write(writer, v),
                .other => |v| {
                    try OptSpec.write(writer, null);
                    try OtherSpec.write(writer, v);
                },
            }
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            var opt_val: OptSpec.UT = undefined;
            try OptSpec.read(reader, &opt_val, a);
            errdefer OptSpec.deinit(&opt_val, a);
            if (opt_val) |v| {
                out.* = .{ .some = v };
            } else {
                out.* = .{ .other = undefined };
                try OtherSpec.read(reader, &out.other, a);
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            switch (self.*) {
                .some => |*v| OptSpec.InnerSpec.deinit(v, a),
                .other => |*v| OtherSpec.deinit(v, a),
            }
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            return switch (self) {
                .some => |v| OptSpec.size(v),
                .other => |v| OptSpec.size(null) + OtherSpec.size(v),
            };
        }
    };
}

pub fn Pass(comptime I: type, comptime T: type) type {
    return struct {
        pub const SourceSpec = Spec(I);
        pub const TargetSpec = Spec(T);
        pub const UT = TargetSpec.UT;
        pub const E = SourceSpec.E || TargetSpec.E;

        pub fn write(writer: anytype, in: UT) !void {
            try SourceSpec.write(writer, TargetSpec.getValue(in));
            try TargetSpec.write(writer, in);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            var value: SourceSpec.UT = undefined;
            try SourceSpec.read(reader, &value, a);
            defer SourceSpec.deinit(&value, a);
            try TargetSpec.read(reader, out, a, value);
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            TargetSpec.deinit(self, a);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            return SourceSpec.size(TargetSpec.getValue(self)) + TargetSpec.size(self);
        }
    };
}

pub fn Pair(comptime M: type, comptime T: type) type {
    return struct {
        pub const MiddleSpec = Spec(M);
        pub const TargetSpec = Spec(T);
        pub const UT = struct {
            m: MiddleSpec.UT,
            t: TargetSpec.UT,
        };
        pub const E = MiddleSpec.E || TargetSpec.E;
        pub const V = TargetSpec.V;

        pub fn getValue(in: UT) V {
            return TargetSpec.getValue(in.t);
        }
        pub fn write(writer: anytype, in: UT) !void {
            try MiddleSpec.write(writer, in.m);
            try TargetSpec.write(writer, in.t);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator, value: anytype) !void {
            try MiddleSpec.read(reader, &out.m, a);
            errdefer MiddleSpec.deinit(&out.m, a);
            try TargetSpec.read(reader, &out.t, a, value);
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            TargetSpec.deinit(&self.t, a);
            MiddleSpec.deinit(&self.m, a);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            return MiddleSpec.size(self.m) + TargetSpec.size(self.t);
        }
    };
}

pub fn TaggedUnion(comptime I: type, comptime T: type) type {
    const UnionSpec = Union(T);
    return Pass(Enum(I, UnionSpec.EnumT), UnionSpec);
}

pub fn Array(comptime T: type) type {
    const info = @typeInfo(T).Array;
    return struct {
        pub const ElemSpec = Spec(info.child);
        pub const UT = [info.len]ElemSpec.UT;
        pub const E = ElemSpec.E;

        pub fn write(writer: anytype, in: UT) !void {
            for (&in) |d| try ElemSpec.write(writer, d);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            if (ElemSpec.UT == u8) {
                try reader.readNoEof(&out.*);
            } else {
                for (out, 0..) |*d, i| {
                    errdefer {
                        var j = i;
                        while (j > 0) {
                            j -= 1;
                            ElemSpec.deinit(&out.*[j], a);
                        }
                    }
                    try ElemSpec.read(reader, d, a);
                }
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            var i: usize = info.len;
            while (i > 0) {
                i -= 1;
                ElemSpec.deinit(&self.*[i], a);
            }
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            var total: usize = 0;
            for (&self) |d| total += ElemSpec.size(d);
            return total;
        }
    };
}

pub fn PrefixedArray(comptime I: type, comptime T: type, comptime opts: struct {
    max: ?comptime_int = null,
}) type {
    return struct {
        pub const LenSpec = Spec(I);
        pub const ElemSpec = Spec(T);
        pub const UT = []ElemSpec.UT;
        pub const E = LenSpec.E || ElemSpec.E || error{ InvalidLength, EndOfStream };

        pub fn write(writer: anytype, in: UT) !void {
            try LenSpec.write(writer, @intCast(in.len));
            if (ElemSpec.UT == u8) {
                try writer.writeAll(in);
            } else {
                for (in) |d| try ElemSpec.write(writer, d);
            }
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            var len_: LenSpec.UT = undefined;
            try LenSpec.read(reader, &len_, a);
            defer LenSpec.deinit(&len_, a);
            const len: usize = std.math.cast(usize, len_) orelse
                return error.InvalidLength;
            if (opts.max) |max_length| {
                if (len > max_length) return error.InvalidLength;
            }
            out.* = try a.alloc(ElemSpec.UT, len);
            errdefer a.free(out.*);
            if (ElemSpec.UT == u8) {
                try reader.readNoEof(out.*);
            } else {
                for (out.*, 0..) |*d, i| {
                    errdefer {
                        var j = i;
                        while (j > 0) {
                            j -= 1;
                            ElemSpec.deinit(&out.*[j], a);
                        }
                    }
                    try ElemSpec.read(reader, d, a);
                }
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                ElemSpec.deinit(&self.*[i], a);
            }
            a.free(self.*);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            var total = LenSpec.size(@intCast(self.len));
            for (self) |d| total += ElemSpec.size(d);
            return total;
        }
    };
}

pub fn Optional(comptime T: type) type {
    return struct {
        pub const InnerSpec = Spec(T);
        pub const UT = ?InnerSpec.UT;
        pub const E = InnerSpec.E;

        pub fn write(writer: anytype, in: UT) !void {
            if (in) |d| {
                try writer.writeByte(0x01);
                try InnerSpec.write(writer, d);
            } else {
                try writer.writeByte(0x00);
            }
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            const has_data = (try reader.readByte()) != 0;
            if (has_data) {
                out.* = @as(InnerSpec.UT, undefined);
                try InnerSpec.read(reader, &(out.*.?), a);
            } else {
                out.* = null;
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            if (self.*) |*inner| InnerSpec.deinit(inner, a);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            return 1 + if (self) |inner| InnerSpec.size(inner) else 0;
        }
    };
}

pub fn Remaining(comptime T: type, comptime opts: struct {
    max: ?comptime_int = null,
    est_size: ?comptime_int = null,
}) type {
    return struct {
        pub const ElemSpec = Spec(T);
        pub const UT = []ElemSpec.UT;
        pub const E = ElemSpec.E || error{EndOfStream};

        pub fn write(writer: anytype, in: UT) !void {
            for (in) |d| try ElemSpec.write(writer, d);
        }
        pub fn read(reader_: anytype, out: *UT, a: Allocator) !void {
            var lr = std.io.limitedReader(
                reader_,
                if (opts.max) |max| max else std.math.maxInt(u64),
            );
            var reader = lr.reader();
            var arr = if (opts.est_size) |est_size|
                try std.ArrayListUnmanaged(ElemSpec.UT).initCapacity(a, est_size)
            else
                std.ArrayListUnmanaged(ElemSpec.UT){};
            defer arr.deinit(a);
            if (ElemSpec.UT == u8) {
                var fifo = std.fifo.LinearFifo(u8, .{ .Static = 512 }).init();
                try fifo.pump(reader, arr.writer(a));
            } else {
                while (true) {
                    errdefer {
                        var i = arr.items.len;
                        while (i > 0) {
                            i -= 1;
                            ElemSpec.deinit(&arr.items[i], a);
                        }
                    }
                    const d = try arr.addOne(a);
                    errdefer arr.items.len -= 1;
                    ElemSpec.read(reader, d, a) catch |e| {
                        if (e == error.EndOfStream) break else return e;
                    };
                }
            }
            out.* = try arr.toOwnedSlice(a);
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                ElemSpec.deinit(&self.*[i], a);
            }
            a.free(self.*);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            var total: usize = 0;
            for (self) |d| total += ElemSpec.size(d);
            return total;
        }
    };
}

pub fn ByteLimited(comptime I: type, comptime T: type, comptime opts: struct {
    max: ?comptime_int = null,
}) type {
    return struct {
        pub const ListSpec = Spec(T);
        pub const LenSpec = Spec(I);
        pub const UT = ListSpec.UT;
        pub const E = ListSpec.E || LenSpec.E || error{ InvalidLength, EndOfStream };

        pub fn write(writer: anytype, in: UT) !void {
            try LenSpec.write(writer, @intCast(in.len));
            try ListSpec.write(writer, in);
        }
        pub fn read(reader_: anytype, out: *UT, a: Allocator) !void {
            var len_: LenSpec.UT = undefined;
            try LenSpec.read(reader_, &len_, a);
            defer LenSpec.deinit(&len_, a);
            const len: usize = std.math.cast(usize, len_) orelse
                return error.InvalidLength;
            if (opts.max) |max_length| {
                if (len > max_length) return error.InvalidLength;
            }
            var lr = std.io.limitedReader(reader_, len);
            try ListSpec.read(lr.reader(), out, a);
            try lr.reader().skipBytes(lr.bytes_left, .{});
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            ListSpec.deinit(self, a);
        }
        pub fn size(self: UT) usize {
            return LenSpec.size(@intCast(self.len)) + ListSpec.size(self);
        }
    };
}

/// backing int probably needs to be bit width multiple of 8
pub fn Packed(comptime T: type, comptime endian: std.builtin.Endian) type {
    const info = @typeInfo(T).Struct;
    comptime std.debug.assert(info.layout == .Packed);
    return struct {
        pub const Backing = info.backing_integer orelse
            @Type(.{ .Int = .{ .signedness = .unsigned, .bits = @bitSizeOf(T) } });
        pub const UT = T;
        pub const E = error{EndOfStream};

        pub fn write(writer: anytype, in: UT) !void {
            try writer.writeInt(@as(Backing, @bitCast(in)), endian);
        }
        pub fn read(reader: anytype, out: *UT, _: Allocator) !void {
            out.* = @bitCast(try reader.readInt(Backing, endian));
        }
        pub fn deinit(self: *UT, _: Allocator) void {
            self.* = undefined;
        }
        pub fn size(_: UT) usize {
            return @sizeOf(UT);
        }
    };
}

pub fn AnyEql(comptime T: type) fn (T, T) bool {
    return (struct {
        pub fn f(_: T, _: T) bool {
            return true;
        }
    }).f;
}
pub fn strEql(a: []const u8, b: []const u8) bool {
    return mem.eql(u8, a, b);
}
pub fn StringEnum(comptime vals: type, comptime T: type) type {
    return MappedEnum(vals, T, strEql);
}
pub fn MappedEnum(comptime vals: type, comptime T: type, comptime eql_: anytype) type {
    const vinfo = @typeInfo(vals).Struct;
    return struct {
        const eql = if (@typeInfo(@TypeOf(eql_)) == .Null) DirectEql(InnerSpec.UT) else eql_;
        pub const EnumT = std.meta.DeclEnum(vals);
        pub const InnerSpec = Spec(T);
        pub const UT = EnumT;
        pub const E = InnerSpec.E || error{InvalidVariant};
        pub fn write(writer: anytype, in: UT) !void {
            switch (in) {
                inline else => |v| {
                    try InnerSpec.write(writer, @field(vals, @tagName(v)));
                },
            }
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            var data: InnerSpec.UT = undefined;
            try InnerSpec.read(reader, &data, a);
            defer InnerSpec.deinit(&data, a);
            inline for (vinfo.decls) |decl| {
                if (eql(@field(vals, decl.name), data)) {
                    out.* = @field(EnumT, decl.name);
                    return;
                }
            }
            if (InnerSpec.UT == []const u8 or InnerSpec.UT == []u8)
                std.debug.print("\nvariant: \"{s}\"\n", .{data});
            return error.InvalidVariant;
        }
        pub fn deinit(self: *UT, _: Allocator) void {
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            return switch (self) {
                inline else => |v| InnerSpec.size(@field(vals, @tagName(v))),
            };
        }
    };
}

pub fn Constant(
    comptime T: type,
    comptime value: Spec(T).UT,
    comptime eql_: ?(fn (Spec(T).UT, Spec(T).UT) bool),
) type {
    return struct {
        const eql = if (eql_ != null) eql_.? else DirectEql(InnerSpec.UT);
        pub const InnerSpec = Spec(T);
        pub const UT = void;
        pub const E = InnerSpec.E || error{InvalidConstant};
        pub fn write(writer: anytype, _: UT) !void {
            try InnerSpec.write(writer, value);
        }
        pub fn read(reader: anytype, _: *UT, a: Allocator) !void {
            var out: InnerSpec.UT = undefined;
            try InnerSpec.read(reader, &out, a);
            defer InnerSpec.deinit(&out, a);
            if (!eql(value, out)) return error.InvalidConstant;
        }
        pub fn deinit(_: *UT, _: Allocator) void {}
        pub fn size(_: UT) usize {
            return 0;
        }
    };
}

pub fn DeepEql(comptime T: type) fn (T, T) bool {
    return (struct {
        pub fn f(a: T, b: T) bool {
            return std.meta.eql(a, b);
        }
    }).f;
}
pub fn DirectEql(comptime T: type) fn (T, T) bool {
    return (struct {
        pub fn f(a: T, b: T) bool {
            return a == b;
        }
    }).f;
}

pub fn ConstantOptional(
    comptime T: type,
    comptime value: Spec(T).UT,
    comptime eql_fn: ?(fn (Spec(T).UT, Spec(T).UT) bool),
) type {
    return struct {
        const eql = eql_fn orelse DirectEql(Spec(T).UT);
        pub const InnerSpec = Spec(T);
        pub const UT = ?InnerSpec.UT;
        pub const E = InnerSpec.E;

        pub fn write(writer: anytype, in: UT) !void {
            try InnerSpec.write(writer, in orelse value);
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            out.* = @as(InnerSpec.UT, undefined);
            try InnerSpec.read(reader, &(out.*.?), a);
            if (eql(out.*.?, value)) {
                InnerSpec.deinit(&out.*.?, a);
                out.* = null;
            }
        }
        pub fn deinit(self: *UT, a: Allocator) void {
            if (self.*) |*inner| InnerSpec.deinit(inner, a);
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            return InnerSpec.size(self orelse value);
        }
    };
}

/// Maps a value. Must provide functions.
/// Your output type should not be an allocated type.
/// map_fns should contain:
/// - const O     // your output type (output when reading, input when writing)
/// - fn from(O) Spec(T).UT                   // user -> writer
/// - fn to(*Spec(T).UT, *O, Allocator) !void // reader -> user
///     // to fn should handle any necessary deallocation of the Spec(T).UT
pub fn Mapped(
    comptime T: type,
    comptime map_fns: type,
) type {
    return struct {
        pub const InnerSpec = Spec(T);
        pub const UT = if (@hasDecl(map_fns, "O")) map_fns.O else InnerSpec.UT;
        pub const E =
            if (@hasDecl(map_fns, "E")) InnerSpec.E || map_fns.E else InnerSpec.E;

        pub fn write(writer: anytype, in: UT) !void {
            try InnerSpec.write(writer, map_fns.from(in));
        }
        pub fn read(reader: anytype, out: *UT, a: Allocator) !void {
            var temp_out: InnerSpec.UT = undefined;
            try InnerSpec.read(reader, &temp_out, a);
            try map_fns.to(&temp_out, out, a);
        }
        pub fn deinit(self: *UT, _: Allocator) void {
            self.* = undefined;
        }
        pub fn size(self: UT) usize {
            return InnerSpec.size(map_fns.from(self));
        }
    };
}
pub fn NumOffset(comptime T: type, comptime offset: comptime_int) type {
    return Mapped(T, struct {
        pub const O = Spec(T).UT;
        pub fn from(in: O) O {
            return if (offset > 0) (in + offset) else (in - (-offset));
        }
        pub fn to(in: *O, out: *O, _: Allocator) !void {
            out.* = if (offset > 0) (in.* - offset) else (in.* + (-offset));
        }
    });
}
pub fn Casted(comptime T: type, comptime Target: type) type {
    return Mapped(T, struct {
        pub const O = Target;
        pub const E = error{InvalidCast};
        pub fn from(in: O) Spec(T).UT {
            return std.math.cast(Spec(T).UT, in).?;
        }
        pub fn to(in: *Spec(T).UT, out: *O, _: Allocator) !void {
            out.* = std.math.cast(O, in.*) orelse return error.InvalidCast;
        }
    });
}

test "serde casted" {
    try doTest(Casted(i16, u8), &.{ 0x00, 0x20 }, 0x20);
}
test "serde numoffset" {
    try doTest(NumOffset(i16, 1), &.{ 0x00, 0x20 }, 0x1F);
}

pub fn BitCasted(comptime T: type, comptime Target: type) type {
    return Mapped(T, struct {
        pub const O = Target;
        pub const E = error{};
        pub fn from(in: O) Spec(T).UT {
            return @bitCast(in);
        }
        pub fn to(in: *Spec(T).UT, out: *O, _: Allocator) !void {
            out.* = @bitCast(in.*);
        }
    });
}

pub fn Spec(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Bool => Bool,
        .Void => Void,
        .Int, .Float => Num(T, .big),
        .Array => Array(T),
        .Optional => |info| Optional(info.child),
        inline .Struct, .Union, .Enum => |info, v| {
            if (v == .Struct and info.layout == .Packed)
                return Packed(T, .big);
            inline for (.{ "read", "write", "deinit", "size" }) |n| {
                if (!@hasDecl(T, n))
                    return switch (v) {
                        .Struct => Struct(T),
                        .Union => TaggedUnion(
                            @typeInfo(info.tag_type.?).Enum.tag_type,
                            T,
                        ),
                        .Enum => Enum(info.tag_type, T),
                        else => unreachable,
                    };
            }
            return T;
        },
        else => @compileError("spec unimplemented for type " ++ @typeName(T)),
    };
}

pub fn doTest(comptime ST: type, buf: []const u8, expected: ST.UT) !void {
    var reader = std.io.fixedBufferStream(buf);
    var result: ST.UT = undefined;
    try ST.read(reader.reader(), &result, testing.allocator);
    defer ST.deinit(&result, testing.allocator);
    try testing.expectEqualDeep(expected, result);
    //std.debug.print("\nexpected: {any}\nresult: {any}\n", .{ expected, result });
    try testing.expectEqual(buf.len, ST.size(result));

    var writebuf = std.ArrayList(u8).init(testing.allocator);
    defer writebuf.deinit();
    try ST.write(writebuf.writer(), result);
    try testing.expectEqualSlices(u8, buf, writebuf.items);
}

test "serde" {
    try doTest(
        Spec(struct {
            const E = enum(u8) { A = 0x00, B = 0x05, C = 0x02 };
            a: i32,
            b: struct {
                c: bool,
                d: u8,
                e: Num(u16, .little),
            },
            c: E,
            d: union(E) {
                A: bool,
                B: u8,
                C: Num(u16, .little),
            },
        }),
        &.{ 0x00, 0x00, 0x01, 0x02, 0x01, 0x08, 0x10, 0x00, 0x02, 0x05, 0x00 },
        .{
            .a = 258,
            .b = .{
                .c = true,
                .d = 0x08,
                .e = 0x10,
            },
            .c = .C,
            .d = .{ .B = 0x00 },
        },
    );
}
