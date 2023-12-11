const std = @import("std");
const root = @import("root");
const testing = std.testing;

pub const v764 = @import("v764.zig");
pub const vlatest = v764;

pub const chunk = @import("chunk.zig");
pub const serde = @import("serde.zig");
pub const nbt = @import("nbt.zig");
pub const varint = @import("varint.zig");
pub const packetio = @import("packetio.zig");

pub const MaxNbtDepth = if (@hasDecl(root, "MaxNbtDepth")) root.MaxNbtDepth else 32;

test {
    testing.refAllDecls(@This());
}
