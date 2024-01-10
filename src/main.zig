const std = @import("std");
const root = @import("root");
const testing = std.testing;

pub const v765 = @import("v765.zig");
pub const vlatest = v765;

pub const chunk = @import("chunk.zig");
pub const serde = @import("serde.zig");
pub const nbt = @import("nbt.zig");
pub const varint = @import("varint.zig");
pub const packetio = @import("packetio.zig");

pub const MaxNbtDepth = if (@hasDecl(root, "MaxNbtDepth")) root.MaxNbtDepth else 32;

// this fn isnt part of minecraft protocol impl
pub fn debugPrint(
    writer: anytype,
    data: anytype,
    // depth cannot be comptime. zig compiler does not like that
    depth: usize,
) @TypeOf(writer).Error!void {
    const T = @TypeOf(data);
    const info = @typeInfo(T);
    if ((info == .Union or info == .Struct or info == .Enum) and
        @hasDecl(T, "format"))
    {
        try data.format("", .{}, writer);
        return;
    }
    switch (info) {
        .Void => try writer.writeAll("{}"),
        .Bool => try writer.writeAll(if (data) "true" else "false"),
        .Int, .Float => try writer.print("{d}", .{data}),
        .Pointer, .Array => {
            if (info == .Pointer) {
                if (info.Pointer.size == .One) {
                    try writer.writeByte('&');
                    try debugPrint(writer, data.*, depth);
                    return;
                }
                if (info.Pointer.size != .Slice) {
                    @compileError("pointer must be slice or one");
                }
            }
            const slice = if (info == .Pointer) data else &data;
            if (std.meta.Child(T) == u8) {
                try writeStringEscaped(writer, slice);
            } else {
                try writer.writeAll((if (info == .Pointer) "&" else "") ++ ".{");
                if (slice.len > 0) {
                    try writer.print(" // {}\n", .{slice.len});
                    for (slice) |elem| {
                        try writer.writeByteNTimes(' ', depth * 2 + 2);
                        if (T == nbt.DynamicCompound.UT) {
                            // TODO: if elem.name is not [a-zA-Z_][a-zA-Z_0-9]* then
                            //     do .@"..." syntax. probably should be done for
                            //     non-nbt as well
                            try writer.print(".{s} = ", .{elem.name});
                            try debugPrint(writer, elem.value, depth + 1);
                        } else {
                            try debugPrint(writer, elem, depth + 1);
                        }
                        try writer.writeAll(",\n");
                    }
                    try writer.writeByteNTimes(' ', depth * 2);
                    try writer.writeAll("}");
                } else {
                    try writer.writeByte('}');
                }
            }
        },
        .Struct => |d| {
            try writer.writeAll(".{");
            switch (d.layout) {
                .Packed => try writer.print(
                    " // packed struct(" ++
                        @typeName(d.backing_integer.?) ++ "): 0x{X}",
                    .{@as(d.backing_integer.?, @bitCast(data))},
                ),
                else => {},
            }
            try writer.writeByte('\n');
            inline for (d.fields) |field| {
                if (!std.mem.startsWith(u8, field.name, "_")) {
                    try writer.writeByteNTimes(' ', depth * 2 + 2);
                    try writer.print(".{s} = ", .{field.name});
                    try debugPrint(writer, @field(data, field.name), depth + 1);
                    try writer.writeAll(",\n");
                }
            }
            try writer.writeByteNTimes(' ', depth * 2);
            try writer.writeAll("}");
        },
        .Union => {
            if (T == nbt.DynamicValue.UT) {
                switch (data) {
                    .end => try writer.writeAll("{}"),
                    .list => |d| {
                        if (d.len == 0) {
                            try writer.writeAll("&.{}");
                        } else {
                            switch (d[0]) {
                                inline .byte,
                                .short,
                                .int,
                                .long,
                                .float,
                                .double,
                                .byte_array,
                                .int_array,
                                .long_array,
                                => |e, v| {
                                    try writer.print(
                                        "&[{}]" ++ @typeName(@TypeOf(e)) ++ "{{\n",
                                        .{d.len},
                                    );
                                    for (d) |elem_| {
                                        const elem = @field(elem_, @tagName(v));
                                        try writer.writeByteNTimes(' ', depth * 2 + 2);
                                        try debugPrint(writer, elem, depth + 1);
                                        try writer.writeAll(",\n");
                                    }
                                    try writer.writeByteNTimes(' ', depth * 2);
                                    try writer.print("}}", .{});
                                },
                                .end => try writer.writeAll("&{}"),
                                inline .compound, .list, .string => |e| {
                                    try debugPrint(writer, e, depth);
                                },
                            }
                        }
                    },
                    .compound => |d| try debugPrint(writer, d, depth),
                    inline else => |d| {
                        try writer.writeAll("@as(" ++ @typeName(@TypeOf(d)) ++ ", ");
                        try debugPrint(writer, d, depth + 1);
                        try writer.writeByte(')');
                    },
                }
            } else {
                try writer.writeAll(".{\n");
                try writer.writeByteNTimes(' ', depth * 2 + 2);
                try writer.writeByte('.');
                try writer.writeAll(@tagName(data));
                try writer.writeAll(" = ");
                switch (data) {
                    inline else => |d| try debugPrint(writer, d, depth + 1),
                }
                try writer.writeAll(",\n");
                try writer.writeByteNTimes(' ', depth * 2);
                try writer.writeByte('}');
            }
        },
        .Enum => try writer.print(".{s}", .{@tagName(data)}),
        .Optional => {
            if (data) |inner_data| {
                try debugPrint(writer, inner_data, depth);
            } else {
                try writer.writeAll("null");
            }
        },
        else => @compileError("unimplemented type"),
    }
}

pub fn writeStringEscaped(writer: anytype, slice: []const u8) !void {
    try writer.writeByte('"');
    for (slice) |b| {
        // TODO: handle unicode
        switch (b) {
            '\n' => try writer.writeAll("\n"),
            '\t' => try writer.writeAll("\t"),
            '\r' => try writer.writeAll("\r"),
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            else => {
                if (std.ascii.isPrint(b)) {
                    try writer.writeByte(b);
                } else {
                    try writer.print("\\0x{X:0>2}", .{b});
                }
            },
        }
    }
    try writer.writeByte('"');
}

test {
    testing.refAllDecls(@This());
}
