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

        pub fn write(writer: anytype, in: T, _: anytype) !void {
            try writer.writeInt(U, @bitCast(in), endian);
        }
        pub fn read(reader: anytype, out: *T, _: anytype) !void {
            out.* = @bitCast(try reader.readInt(U, endian));
        }
        pub fn deinit(self: *T, _: anytype) void {
            self.* = undefined;
        }
        pub fn size(_: T, _: anytype) usize {
            return @sizeOf(T);
        }
    };
}

pub const Bool = struct {
    pub const UT = bool;
    pub const E = error{EndOfStream};
    pub fn write(writer: anytype, in: bool, _: anytype) !void {
        try writer.writeByte(@intFromBool(in));
    }
    pub fn read(reader: anytype, out: *bool, _: anytype) !void {
        out.* = (try reader.readByte()) != 0;
    }
    pub fn deinit(self: *bool, _: anytype) void {
        self.* = undefined;
    }
    pub fn size(_: bool, _: anytype) usize {
        return 1;
    }
};

pub const Void = struct {
    pub const UT = void;
    pub const E = error{};
    pub fn write(_: anytype, _: void, _: anytype) !void {}
    pub fn read(_: anytype, _: *void, _: anytype) !void {}
    pub fn deinit(_: *void, _: anytype) void {}
    pub fn size(_: void, _: anytype) usize {
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
            .default_value = switch (@typeInfo(T)) {
                .Optional => &@as(T, null),
                .Void => &{},
                else => null,
            },
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
    inline for (&fields, ifields, specs) |*field, ifield, spec| {
        field.* = builtinField(
            ifield,
            if (@typeInfo(T) == .Enum)
                void
            else if (@hasDecl(spec, "IsOptional")) ?spec.UT else spec.UT,
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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            inline for (info.fields, 0..) |field, i| {
                try specs[i].write(writer, @field(in, field.name), ctx);
            }
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            inline for (info.fields, 0..) |field, i| {
                errdefer {
                    comptime var j = i;
                    inline while (j > 0) {
                        j -= 1;
                        specs[j].deinit(&@field(out, info.fields[j].name), ctx);
                    }
                }
                try specs[i].read(reader, &@field(out, field.name), ctx);
            }
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            comptime var i = info.fields.len;
            inline while (i > 0) {
                i -= 1;
                specs[i].deinit(&@field(self, info.fields[i].name), ctx);
            }
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            var total: usize = 0;
            inline for (info.fields, 0..) |field, i| {
                total += specs[i].size(@field(self, field.name), ctx);
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

        pub fn write(writer: anytype, in: T, ctx: anytype) !void {
            try TagSpec.write(writer, getInt(in), ctx);
        }
        pub fn read(reader: anytype, out: *T, ctx: anytype) !void {
            var n: TagSpec.UT = undefined;
            try TagSpec.read(reader, &n, ctx);
            defer TagSpec.deinit(&n, ctx);
            out.* = try std.meta.intToEnum(UT, @as(EnumI, @intCast(n)));
        }
        pub fn deinit(self: *T, _: anytype) void {
            self.* = undefined;
        }
        pub fn size(self: T, ctx: anytype) usize {
            return TagSpec.size(getInt(self), ctx);
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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            switch (in) {
                inline else => |d, v| {
                    try specs[comptime tagI(v)].write(writer, d, ctx);
                },
            }
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype, tag: EnumT) !void {
            switch (tag) {
                inline else => |v| {
                    out.* = @unionInit(UT, @tagName(v), undefined);
                    try specs[comptime tagI(v)].read(
                        reader,
                        &@field(out, @tagName(v)),
                        ctx,
                    );
                },
            }
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            switch (self.*) {
                inline else => |*d, v| {
                    specs[comptime tagI(v)].deinit(d, ctx);
                },
            }
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return switch (self) {
                inline else => |d, v| specs[comptime tagI(v)].size(d, ctx),
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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            switch (in) {
                .some => |v| try OptSpec.write(writer, v, ctx),
                .other => |v| {
                    try OptSpec.write(writer, null, ctx);
                    try OtherSpec.write(writer, v, ctx);
                },
            }
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            var opt_val: OptSpec.UT = undefined;
            try OptSpec.read(reader, &opt_val, ctx);
            errdefer OptSpec.deinit(&opt_val, ctx);
            if (opt_val) |v| {
                out.* = .{ .some = v };
            } else {
                out.* = .{ .other = undefined };
                try OtherSpec.read(reader, &out.other, ctx);
            }
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            switch (self.*) {
                .some => |*v| OptSpec.InnerSpec.deinit(v, ctx),
                .other => |*v| OtherSpec.deinit(v, ctx),
            }
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return switch (self) {
                .some => |v| OptSpec.size(v, ctx),
                .other => |v| OptSpec.size(null, ctx) + OtherSpec.size(v, ctx),
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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            try SourceSpec.write(writer, TargetSpec.getValue(in), ctx);
            try TargetSpec.write(writer, in, ctx);
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            var value: SourceSpec.UT = undefined;
            try SourceSpec.read(reader, &value, ctx);
            defer SourceSpec.deinit(&value, ctx);
            try TargetSpec.read(reader, out, ctx, value);
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            TargetSpec.deinit(self, ctx);
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return SourceSpec.size(TargetSpec.getValue(self), ctx) +
                TargetSpec.size(self, ctx);
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
        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            try MiddleSpec.write(writer, in.m, ctx);
            try TargetSpec.write(writer, in.t, ctx);
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype, value: anytype) !void {
            try MiddleSpec.read(reader, &out.m, ctx);
            errdefer MiddleSpec.deinit(&out.m, ctx);
            try TargetSpec.read(reader, &out.t, ctx, value);
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            TargetSpec.deinit(&self.t, ctx);
            MiddleSpec.deinit(&self.m, ctx);
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return MiddleSpec.size(self.m, ctx) + TargetSpec.size(self.t, ctx);
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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            for (&in) |d| try ElemSpec.write(writer, d, ctx);
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            if (ElemSpec.UT == u8) {
                try reader.readNoEof(&out.*);
            } else {
                for (out, 0..) |*d, i| {
                    errdefer {
                        var j = i;
                        while (j > 0) {
                            j -= 1;
                            ElemSpec.deinit(&out.*[j], ctx);
                        }
                    }
                    try ElemSpec.read(reader, d, ctx);
                }
            }
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            var i: usize = info.len;
            while (i > 0) {
                i -= 1;
                ElemSpec.deinit(&self.*[i], ctx);
            }
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            var total: usize = 0;
            for (&self) |d| total += ElemSpec.size(d, ctx);
            return total;
        }
    };
}

pub fn BoundedDynamicArray(comptime T: type, comptime capacity: comptime_int) type {
    return struct {
        pub const InnerArray = DynamicArray(T);
        pub const UT = std.BoundedArray(InnerArray.ElemSpec.UT, capacity);
        pub const E = InnerArray.E || error{InvalidInt};
        pub const V = Length;

        pub const Length = std.math.IntFittingRange(0, capacity);

        pub fn getValue(in: UT) V {
            return in.len;
        }
        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            try InnerArray.write(writer, in.constSlice(), ctx);
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype, len: V) !void {
            if (len > capacity) return error.InvalidInt;
            out.len = len;
            var slice_: []const InnerArray.ElemSpec.UT = undefined;
            try InnerArray.readWithBuffer(reader, &slice_, out.buffer[0..len], ctx);
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            var slice = self.slice();
            InnerArray.deinit(&slice, ctx);
        }
        pub fn size(self: UT, ctx: anytype) usize {
            var total: usize = 0;
            for (self.constSlice()) |d| total += InnerArray.ElemSpec.size(d, ctx);
            return total;
        }
    };
}

pub fn DynamicArray(comptime T: type) type {
    return struct {
        pub const ElemSpec = Spec(T);
        pub const UT = []const ElemSpec.UT;
        pub const E = ElemSpec.E || error{EndOfStream};
        pub const V = usize;

        pub fn getValue(in: UT) V {
            return in.len;
        }
        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            if (ElemSpec.UT == u8) {
                try writer.writeAll(in);
            } else {
                for (in) |d| try ElemSpec.write(writer, d, ctx);
            }
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype, len: V) !void {
            const arr = try ctx.allocator.alloc(ElemSpec.UT, len);
            errdefer ctx.allocator.free(arr);
            try readWithBuffer(reader, out, arr, ctx);
        }
        pub fn readWithBuffer(
            reader: anytype,
            out: *UT,
            buf: []ElemSpec.UT,
            ctx: anytype,
        ) !void {
            if (ElemSpec.UT == u8) {
                try reader.readNoEof(buf);
            } else {
                for (buf, 0..) |*d, i| {
                    errdefer {
                        var j = i;
                        while (j > 0) {
                            j -= 1;
                            ElemSpec.deinit(&buf[j], ctx);
                        }
                    }
                    try ElemSpec.read(reader, d, ctx);
                }
            }
            out.* = buf;
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                ElemSpec.deinit(@constCast(&self.*[i]), ctx);
            }
            ctx.allocator.free(self.*);
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            var total: usize = 0;
            for (self) |d| total += ElemSpec.size(d, ctx);
            return total;
        }
    };
}

pub const CodepointArray = struct {
    pub const UT = []const u8;
    pub const E = std.unicode.Utf8DecodeError || error{
        TruncatedInput,
        StringTooLarge,
        EndOfStream,
    };
    pub const V = usize;

    pub fn getValue(self: UT) V {
        return std.unicode.utf8CountCodepoints(self) catch unreachable;
    }
    pub fn write(writer: anytype, in: UT, _: anytype) !void {
        try writer.writeAll(in);
    }

    pub fn read(reader: anytype, out: *UT, ctx: anytype, len: V) !void {
        var data = try std.ArrayList(u8).initCapacity(ctx.allocator, len);
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
    pub fn deinit(self: *UT, ctx: anytype) void {
        ctx.allocator.free(self.*);
        self.* = undefined;
    }
    pub fn size(self: UT, _: anytype) usize {
        return self.len;
    }
};

pub const RestrictIntOptions = struct {
    min: ?comptime_int = null,
    max: ?comptime_int = null,
};
pub fn RestrictInt(comptime T: type, comptime opts: RestrictIntOptions) type {
    return struct {
        pub const InnerSpec = Spec(T);
        pub const UT = InnerSpec.UT;
        pub const E = InnerSpec.E || error{InvalidInt};

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            try InnerSpec.write(writer, in, ctx);
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            try InnerSpec.read(reader, out, ctx);
            errdefer InnerSpec.deinit(out, ctx);
            if (opts.max) |max| {
                if (out.* > max) return error.InvalidInt;
            }
            if (opts.min) |min| {
                if (out.* < min) return error.InvalidInt;
            }
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            InnerSpec.deinit(self, ctx);
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return InnerSpec.size(self, ctx);
        }
    };
}

pub fn PrefixedArray(
    comptime I: type,
    comptime T: type,
    comptime opts: RestrictIntOptions,
) type {
    return Pass(RestrictInt(Casted(I, usize), opts), DynamicArray(T));
}

pub fn Optional(comptime T: type) type {
    return struct {
        pub const InnerSpec = Spec(T);
        pub const UT = ?InnerSpec.UT;
        pub const E = InnerSpec.E;

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            if (in) |d| {
                try writer.writeByte(0x01);
                try InnerSpec.write(writer, d, ctx);
            } else {
                try writer.writeByte(0x00);
            }
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            const has_data = (try reader.readByte()) != 0;
            if (has_data) {
                out.* = @as(InnerSpec.UT, undefined);
                try InnerSpec.read(reader, &(out.*.?), ctx);
            } else {
                out.* = null;
            }
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            if (self.*) |*inner| InnerSpec.deinit(inner, ctx);
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return 1 + if (self) |inner| InnerSpec.size(inner, ctx) else 0;
        }
    };
}

pub fn Remaining(comptime T: type, comptime opts: struct {
    max: ?comptime_int = null,
    est_size: ?comptime_int = null,
}) type {
    return struct {
        pub const ElemSpec = Spec(T);
        pub const UT = []const ElemSpec.UT;
        pub const E = ElemSpec.E || error{EndOfStream};

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            for (in) |d| try ElemSpec.write(writer, d, ctx);
        }
        pub fn read(reader_: anytype, out: *UT, ctx: anytype) !void {
            var lr = std.io.limitedReader(
                reader_,
                if (opts.max) |max| max else std.math.maxInt(u64),
            );
            const reader = lr.reader();
            var arr = if (opts.est_size) |est_size|
                try std.ArrayListUnmanaged(ElemSpec.UT)
                    .initCapacity(ctx.allocator, est_size)
            else
                std.ArrayListUnmanaged(ElemSpec.UT){};
            defer arr.deinit(ctx.allocator);
            if (ElemSpec.UT == u8) {
                var fifo = std.fifo.LinearFifo(u8, .{ .Static = 512 }).init();
                try fifo.pump(reader, arr.writer(ctx.allocator));
            } else {
                while (true) {
                    errdefer {
                        var i = arr.items.len;
                        while (i > 0) {
                            i -= 1;
                            ElemSpec.deinit(&arr.items[i], ctx);
                        }
                    }
                    const d = try arr.addOne(ctx.allocator);
                    const last_count = lr.bytes_left;
                    // should not read anything if there is nothing left
                    ElemSpec.read(reader, d, ctx) catch |e| {
                        arr.items.len -= 1;
                        if (e == error.EndOfStream and last_count == lr.bytes_left)
                            break;
                        return e;
                    };
                }
            }
            out.* = try arr.toOwnedSlice(ctx.allocator);
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                ElemSpec.deinit(@constCast(&self.*[i]), ctx);
            }
            ctx.allocator.free(self.*);
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            var total: usize = 0;
            for (self) |d| total += ElemSpec.size(d, ctx);
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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            try LenSpec.write(writer, @intCast(ListSpec.size(in, ctx)), ctx);
            try ListSpec.write(writer, in, ctx);
        }
        pub fn read(reader_: anytype, out: *UT, ctx: anytype) !void {
            var len_: LenSpec.UT = undefined;
            try LenSpec.read(reader_, &len_, ctx);
            defer LenSpec.deinit(&len_, ctx);
            const len: usize = std.math.cast(usize, len_) orelse
                return error.InvalidLength;
            if (opts.max) |max_length| {
                if (len > max_length) return error.InvalidLength;
            }
            var lr = std.io.limitedReader(reader_, len);
            try ListSpec.read(lr.reader(), out, ctx);
            errdefer ListSpec.deinit(out, ctx);
            try lr.reader().skipBytes(lr.bytes_left, .{});
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            ListSpec.deinit(self, ctx);
        }
        pub fn size(self: UT, ctx: anytype) usize {
            const payload_byte_len = ListSpec.size(self, ctx);
            return LenSpec.size(@intCast(payload_byte_len), ctx) + payload_byte_len;
        }
    };
}

test "byte limited" {
    try doTestOnValue(
        PrefixedArray(u8, PrefixedArray(u8, u8, .{}), .{}),
        &.{
            &.{ 0, 1, 2, 3 },
            &.{ 4, 5, 6 },
            &.{ 7, 8 },
            &.{ 9, 10, 11, 12, 13, 14, 15, 16, 17 },
            &.{ 18, 19 },
        },
        true,
    );
    try doTestOnValue(
        ByteLimited(u16, Remaining(PrefixedArray(u8, u8, .{}), .{}), .{}),
        &.{
            &.{ 0, 1, 2, 3 },
            &.{ 4, 5, 6 },
            &.{ 7, 8 },
            &.{ 9, 10, 11, 12, 13, 14, 15, 16, 17 },
            &.{ 18, 19 },
        },
        true,
    );
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

        pub fn write(writer: anytype, in: UT, _: anytype) !void {
            try writer.writeInt(Backing, @bitCast(in), endian);
        }
        pub fn read(reader: anytype, out: *UT, _: anytype) !void {
            out.* = @bitCast(try reader.readInt(Backing, endian));
        }
        pub fn deinit(self: *UT, _: anytype) void {
            self.* = undefined;
        }
        pub fn size(_: UT, _: anytype) usize {
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
        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            switch (in) {
                inline else => |v| {
                    try InnerSpec.write(writer, @field(vals, @tagName(v)), ctx);
                },
            }
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            var data: InnerSpec.UT = undefined;
            try InnerSpec.read(reader, &data, ctx);
            defer InnerSpec.deinit(&data, ctx);
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
        pub fn deinit(self: *UT, _: anytype) void {
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return switch (self) {
                inline else => |v| InnerSpec.size(@field(vals, @tagName(v)), ctx),
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
        pub fn write(writer: anytype, _: UT, ctx: anytype) !void {
            try InnerSpec.write(writer, value, ctx);
        }
        pub fn read(reader: anytype, _: *UT, ctx: anytype) !void {
            var out: InnerSpec.UT = undefined;
            try InnerSpec.read(reader, &out, ctx);
            defer InnerSpec.deinit(&out, ctx);
            if (!eql(value, out)) return error.InvalidConstant;
        }
        pub fn deinit(_: *UT, _: anytype) void {}
        pub fn size(_: UT, ctx: anytype) usize {
            return InnerSpec.size(value, ctx);
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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            try InnerSpec.write(writer, in orelse value, ctx);
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            out.* = @as(InnerSpec.UT, undefined);
            try InnerSpec.read(reader, &(out.*.?), ctx);
            if (eql(out.*.?, value)) {
                InnerSpec.deinit(&out.*.?, ctx);
                out.* = null;
            }
        }
        pub fn deinit(self: *UT, ctx: anytype) void {
            if (self.*) |*inner| InnerSpec.deinit(inner, ctx);
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return InnerSpec.size(self orelse value, ctx);
        }
    };
}

/// Maps a value. Must provide functions.
/// Your output type should not be an allocated type.
/// map_fns should contain:
/// - const O     // your output type (output when reading, input when writing)
/// - fn from(O) Spec(T).UT                   // user -> writer
/// - fn to(*Spec(T).UT, *O, ctx) !void // reader -> user
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

        pub fn write(writer: anytype, in: UT, ctx: anytype) !void {
            try InnerSpec.write(writer, map_fns.from(in), ctx);
        }
        pub fn read(reader: anytype, out: *UT, ctx: anytype) !void {
            var temp_out: InnerSpec.UT = undefined;
            try InnerSpec.read(reader, &temp_out, ctx);
            try map_fns.to(&temp_out, out, ctx);
        }
        pub fn deinit(self: *UT, _: anytype) void {
            self.* = undefined;
        }
        pub fn size(self: UT, ctx: anytype) usize {
            return InnerSpec.size(map_fns.from(self), ctx);
        }
    };
}
pub fn NumOffset(comptime T: type, comptime offset: comptime_int) type {
    return Mapped(T, struct {
        pub const O = Spec(T).UT;
        pub fn from(in: O) O {
            return if (offset > 0) (in + offset) else (in - (-offset));
        }
        pub fn to(in: *O, out: *O, _: anytype) !void {
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
        pub fn to(in: *Spec(T).UT, out: *O, _: anytype) !void {
            out.* = std.math.cast(O, in.*) orelse return error.InvalidCast;
        }
    });
}

test "serde casted" {
    try doTest(Casted(i16, u8), &.{ 0x00, 0x20 }, 0x20, false);
}
test "serde numoffset" {
    try doTest(NumOffset(i16, 1), &.{ 0x00, 0x20 }, 0x1F, false);
}

pub fn BitCasted(comptime T: type, comptime Target: type) type {
    return Mapped(T, struct {
        pub const O = Target;
        pub const E = error{};
        pub fn from(in: O) Spec(T).UT {
            return @bitCast(in);
        }
        pub fn to(in: *Spec(T).UT, out: *O, _: anytype) !void {
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

pub fn doTest(
    comptime ST: type,
    buf: []const u8,
    expected: ST.UT,
    comptime check_allocations: bool,
) !void {
    var reader = std.io.fixedBufferStream(buf);
    var result: ST.UT = undefined;
    try ST.read(reader.reader(), &result, .{ .allocator = testing.allocator });
    defer ST.deinit(&result, .{ .allocator = testing.allocator });
    try testing.expectEqualDeep(expected, result);
    //std.debug.print("\nexpected: {any}\nresult: {any}\n", .{ expected, result });
    try testing.expectEqual(buf.len, ST.size(result, .{}));

    var writebuf = std.ArrayList(u8).init(testing.allocator);
    defer writebuf.deinit();
    try ST.write(writebuf.writer(), result, .{});
    try testing.expectEqualSlices(u8, buf, writebuf.items);

    if (check_allocations) {
        testing.checkAllAllocationFailures(testing.allocator, (struct {
            pub fn read(allocator: Allocator, data: []const u8) !void {
                var stream = std.io.fixedBufferStream(data);
                var r: ST.UT = undefined;
                try ST.read(stream.reader(), &r, .{ .allocator = allocator });
                ST.deinit(&r, .{ .allocator = allocator });
            }
        }).read, .{buf}) catch |e| {
            if (e != error.SwallowedOutOfMemoryError) return e;
        };
    }
}
pub fn doTestOnValue(
    comptime ST: type,
    value: ST.UT,
    comptime check_allocations: bool,
) !void {
    var writebuf = std.ArrayList(u8).init(testing.allocator);
    defer writebuf.deinit();
    try ST.write(writebuf.writer(), value, .{});

    var stream = std.io.fixedBufferStream(writebuf.items);
    var result: ST.UT = undefined;
    try ST.read(stream.reader(), &result, .{ .allocator = testing.allocator });
    defer ST.deinit(&result, .{ .allocator = testing.allocator });

    {
        errdefer std.debug.print("\ngot {any}\n", .{result});
        try testing.expectEqualDeep(value, result);
    }
    try testing.expectEqual(writebuf.items.len, ST.size(result, .{}));

    if (check_allocations) {
        testing.checkAllAllocationFailures(testing.allocator, (struct {
            pub fn read(allocator: Allocator, data: []const u8) !void {
                var stream_ = std.io.fixedBufferStream(data);
                var r: ST.UT = undefined;
                try ST.read(stream_.reader(), &r, .{ .allocator = allocator });
                ST.deinit(&r, .{ .allocator = allocator });
            }
        }).read, .{writebuf.items}) catch |e| {
            if (e != error.SwallowedOutOfMemoryError) return e;
        };
    }
}

test "serde" {
    try doTest(Spec(struct {
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
        e: PrefixedArray(Num(u16, .big), struct {
            a: enum(u8) { f = 0x00, g = 0x01, h = 0x02 },
            b: i8,
        }, .{}),
    }), &.{
        0x00, 0x00, 0x01, 0x02, 0x01, 0x08, 0x10, 0x00, 0x02, 0x05, 0x00,
        0x00, 0x03, 0x02, 0x03, 0x02, 0x05, 0x01, 0x06,
    }, .{
        .a = 258,
        .b = .{
            .c = true,
            .d = 0x08,
            .e = 0x10,
        },
        .c = .C,
        .d = .{ .B = 0x00 },
        .e = &.{ .{ .a = .h, .b = 3 }, .{ .a = .h, .b = 5 }, .{ .a = .g, .b = 6 } },
    }, true);
}
