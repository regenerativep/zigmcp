const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const testing = std.testing;

const serde = @import("serde.zig");

const VarInt = @import("varint.zig").VarInt;
const VarI32 = VarInt(i32);

const nbt = @import("nbt.zig");
const MaxNbtDepth = @import("main.zig").MaxNbtDepth;

//pub const ChatCompound = nbt.Compound(struct {
//    text: ?[]const u8,
//    bold: ?bool,
//    italic: ?bool,
//    underlined: ?bool,
//    strikethrough: ?bool,
//    obfuscated: ?bool,
//    font: ?[]const u8,
//    color: ?[]const u8,
//    insertion: ?[]const u8,
//    click_event: nbt.WithName("clickEvent", ?struct {
//        action: nbt.StringEnum(struct {
//            pub const open_url = "open_url";
//            pub const run_command = "run_command";
//            pub const suggest_command = "suggest_command";
//            pub const change_page = "change_page";
//            pub const copy_to_clipboard = "copy_to_clipboard";
//        }),
//        value: []const u8,
//    }),
//    hover_event: nbt.WithName("clickEvent", ?struct {
//        action: nbt.StringEnum(struct {
//            pub const show_text = "show_text";
//            pub const show_item = "show_item";
//            pub const show_entity = "show_entity";
//        }),
//        content: nbt.Dynamic(.any, MaxNbtDepth),
//    }),
//    extra: ?[]const Chat,

//    translate: ?[]const u8,
//    with: ?[]const Chat,

//    keybind: ?[]const u8,

//    score: ?struct {
//        name: []const u8,
//        objective: []const u8,
//        value: ?nbt.Dynamic(.any, MaxNbtDepth),
//    },

//    selector: ?[]const u8,
//    separator: ?[]const u8,

//    nbt: ?nbt.Dynamic(.any, MaxNbtDepth),
//});
pub const Chat = nbt.Multiple(union(enum) {
    string: []const u8,
    //compound: nbt.Compound(struct {
    //    text: ?[]const u8,
    //}),
    //compound: ChatCompound,
    compound: nbt.Dynamic(.compound, MaxNbtDepth),
});
