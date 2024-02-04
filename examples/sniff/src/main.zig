const std = @import("std");
const io = std.io;
const mem = std.mem;
const Allocator = mem.Allocator;
const net = std.net;
const time = std.time;
const fmt = std.fmt;

const mcp = @import("mcp");
const mcio = mcp.packetio;
const mcv = mcp.vlatest;

pub const PacketKind = enum {
    handshake,
    status,
    login,
    configuration,
    play,
};
pub const PacketSet = struct {
    pub const Cb = struct {
        handshake: std.EnumSet(mcv_H_CBID) = std.EnumSet(mcv_H_CBID).initEmpty(),
        status: std.EnumSet(mcv.S.CBID) = std.EnumSet(mcv.S.CBID).initEmpty(),
        login: std.EnumSet(mcv.L.CBID) = std.EnumSet(mcv.L.CBID).initEmpty(),
        configuration: std.EnumSet(mcv.C.CBID) = std.EnumSet(mcv.C.CBID).initEmpty(),
        play: std.EnumSet(mcv.P.CBID) = std.EnumSet(mcv.P.CBID).initEmpty(),
    };
    pub const Sb = struct {
        handshake: std.EnumSet(mcv.H.SBID) = std.EnumSet(mcv.H.SBID).initEmpty(),
        status: std.EnumSet(mcv.S.SBID) = std.EnumSet(mcv.S.SBID).initEmpty(),
        login: std.EnumSet(mcv.L.SBID) = std.EnumSet(mcv.L.SBID).initEmpty(),
        configuration: std.EnumSet(mcv.C.SBID) = std.EnumSet(mcv.C.SBID).initEmpty(),
        play: std.EnumSet(mcv.P.SBID) = std.EnumSet(mcv.P.SBID).initEmpty(),
    };

    cb: Cb = .{},
    sb: Sb = .{},

    pub fn initAll() PacketSet {
        var self: PacketSet = undefined;
        self.cb.handshake = std.EnumSet(mcv_H_CBID).initFull();
        self.cb.status = std.EnumSet(mcv.S.CBID).initFull();
        self.cb.login = std.EnumSet(mcv.L.CBID).initFull();
        self.cb.configuration = std.EnumSet(mcv.C.CBID).initFull();
        self.cb.play = std.EnumSet(mcv.P.CBID).initFull();
        self.sb.handshake = std.EnumSet(mcv.H.SBID).initFull();
        self.sb.status = std.EnumSet(mcv.S.SBID).initFull();
        self.sb.login = std.EnumSet(mcv.L.SBID).initFull();
        self.sb.configuration = std.EnumSet(mcv.C.SBID).initFull();
        self.sb.play = std.EnumSet(mcv.P.SBID).initFull();
        return self;
    }

    pub fn insert(self: *PacketSet, id: PacketId) void {
        switch (id) {
            inline else => |d1, v1| {
                switch (d1) {
                    inline else => |d2, v2| {
                        @field(@field(self, @tagName(v1)), @tagName(v2)).insert(d2);
                    },
                }
            },
        }
    }
    pub fn remove(self: *PacketSet, id: PacketId) void {
        switch (id) {
            inline else => |d1, v1| {
                switch (d1) {
                    inline else => |d2, v2| {
                        @field(@field(self, @tagName(v1)), @tagName(v2)).remove(d2);
                    },
                }
            },
        }
    }
    pub fn contains(self: PacketSet, id: PacketId) bool {
        switch (id) {
            inline else => |d1, v1| {
                switch (d1) {
                    inline else => |d2, v2| {
                        return @field(@field(self, @tagName(v1)), @tagName(v2))
                            .contains(d2);
                    },
                }
            },
        }
    }
};

pub const Options = struct {
    start_time: i128 = 0,

    shown_packets: PacketSet = .{},
    contents_packets: PacketSet = .{},
};

pub const mcv_H_CBID = enum {};
pub const PacketId = union(enum) {
    pub const Sb = union(PacketKind) {
        handshake: mcv.H.SBID,
        status: mcv.S.SBID,
        login: mcv.L.SBID,
        configuration: mcv.C.SBID,
        play: mcv.P.SBID,
    };
    pub const Cb = union(PacketKind) {
        handshake: mcv_H_CBID,
        status: mcv.S.CBID,
        login: mcv.L.CBID,
        configuration: mcv.C.CBID,
        play: mcv.P.CBID,
    };

    sb: Sb,
    cb: Cb,
};

fn stringToPacketId(text: []const u8) ?PacketId {
    @setEvalBranchQuota(1_600);
    if (text.len < 5 or text[1] != '.' or text[4] != '.' or text[3] != 'b') return null;
    switch (std.ascii.toLower(text[0])) {
        inline 'h', 's', 'l', 'c', 'p' => |c1| {
            switch (text[2]) {
                inline 'c', 's' => |c2| {
                    const S = if (c2 == 's') switch (c1) {
                        'h' => mcv.H.SBID,
                        's' => mcv.S.SBID,
                        'l' => mcv.L.SBID,
                        'c' => mcv.C.SBID,
                        'p' => mcv.P.SBID,
                        else => unreachable,
                    } else switch (c1) {
                        'h' => mcv_H_CBID,
                        's' => mcv.S.CBID,
                        'l' => mcv.L.CBID,
                        'c' => mcv.C.CBID,
                        'p' => mcv.P.CBID,
                        else => unreachable,
                    };
                    return @unionInit(
                        PacketId,
                        if (c2 == 's') "sb" else "cb",
                        @unionInit(
                            if (c2 == 's') PacketId.Sb else PacketId.Cb,
                            switch (c1) {
                                'h' => "handshake",
                                's' => "status",
                                'l' => "login",
                                'c' => "configuration",
                                'p' => "play",
                                else => unreachable,
                            },
                            std.meta.stringToEnum(S, text[5..]) orelse return null,
                        ),
                    );
                },
                else => return null,
            }
        },
        else => return null,
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var options = Options{};

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--contents")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                if (mem.eql(u8, args[i], "all")) {
                    options.shown_packets = PacketSet.initAll();
                    options.contents_packets = PacketSet.initAll();
                } else if (mem.eql(u8, args[i], "none")) {
                    options.contents_packets = .{};
                } else {
                    const pid = stringToPacketId(args[i]) orelse {
                        i -= 1;
                        break;
                    };
                    options.shown_packets.insert(pid);
                    options.contents_packets.insert(pid);
                }
            }
        } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--show")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                if (mem.eql(u8, args[i], "all")) {
                    options.shown_packets = PacketSet.initAll();
                } else if (mem.eql(u8, args[i], "none")) {
                    options.shown_packets = .{};
                } else {
                    options.shown_packets.insert(stringToPacketId(args[i]) orelse {
                        i -= 1;
                        break;
                    });
                }
            }
        } else if (mem.eql(u8, arg, "-n") or mem.eql(u8, arg, "--hide")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                if (mem.eql(u8, args[i], "all")) {
                    options.shown_packets = .{};
                    options.contents_packets = .{};
                } else if (mem.eql(u8, args[i], "none")) {
                    options.shown_packets = PacketSet.initAll();
                    options.contents_packets = PacketSet.initAll();
                } else {
                    const pid = stringToPacketId(args[i]) orelse {
                        i -= 1;
                        break;
                    };
                    options.shown_packets.remove(pid);
                    options.contents_packets.remove(pid);
                }
            }
        } else if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            print(
                \\sniff
                \\Peek into the packets sent between a Minecraft server and client.
                \\
                \\    -c, --contents [<command>|all|none [...]]
                \\    Displays contents of specified packets
                \\
                \\    -n, --hide [<command>|all|none [...]]
                \\    -s, --show [<command>|all|none [...]]
                \\    Explicitly specifies that certain packets should be printed.
                \\
                \\    -h, --help
                \\    Shows this message.
                \\
                \\By default, no packets will be printed. By default, no shown packets
                \\will have their contents displayed.
                \\
                \\Display all every packet and its contents:
                \\    ./sniff -c all
                \\Display every packet without its contents:
                \\    ./sniff -s all
                \\Display everything but a certain packet:
                \\    ./sniff -s all -n p.cb.chunk_data_and_update_light
                \\Display all packet contents except only print title of one packet:
                \\    ./sniff -c all -n p.cb.chunk_data_and_update_light -s p.cb.chunk_data_and_update_light
                \\
            , .{});
            return;
        } else {
            print("Unknown argument \"{s}\"", .{arg});
            return;
        }
    }

    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 25400);
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(address);

    print("Listening on {}\n", .{address});

    while (true) {
        const conn = server.accept() catch |e| {
            std.log.err("Connection failure: {any}", .{e});
            continue;
        };
        print("Connection from {}\n", .{conn.address});
        options.start_time = time.nanoTimestamp();
        handleServerbound(gpa.allocator(), conn, options) catch |e| {
            if (e != error.EndOfStream) {
                std.log.err("Error handling client from {}, {any}", .{ conn.address, e });
            } else {
                print("finished handling {}\n", .{conn.address});
            }
            continue;
        };
    }
}

var stdout_mutex = std.Thread.Mutex{};
var stdout_b = io.bufferedWriter(io.getStdOut().writer());
var stdout = stdout_b.writer();
fn print(comptime fmt_: [:0]const u8, args: anytype) void {
    stdout_mutex.lock();
    defer stdout_mutex.unlock();
    stdout.print(fmt_, args) catch {};
    stdout_b.flush() catch {};
}

const CurrentState = PacketKind;
pub fn handleServerbound(
    a: Allocator,
    conn: net.StreamServer.Connection,
    options: Options,
) !void {
    @setEvalBranchQuota(10_000);

    var cbr = io.bufferedReader(conn.stream.reader());
    var cbw = io.bufferedWriter(conn.stream.writer());
    const cr = cbr.reader();

    var alive_mutex = std.Thread.Mutex{};
    var alive: bool = true;

    var clientbound_thread: ?std.Thread = null;

    defer {
        alive_mutex.lock();
        if (alive) conn.stream.close();
        alive = false;
        alive_mutex.unlock();
        if (clientbound_thread) |*t| t.join();
    }

    var current_state: CurrentState = .handshake;

    defer stdout_b.flush() catch {};

    // -- receive client handshake
    var handshake_packet =
        try mcio.readHandshakePacket(mcv.H.SB, cr, .{ .allocator = a });
    defer mcv.H.SB.deinit(&handshake_packet, .{ .allocator = a });
    if (handshake_packet == .legacy) return;

    // -- connect to server
    const server_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 25565);
    var server_connection = try net.tcpConnectToAddress(server_address);
    defer server_connection.close();

    var sbr = io.bufferedReader(server_connection.reader());
    var sbw = io.bufferedWriter(server_connection.writer());
    const sw = sbw.writer();

    // -- pass along handshake to server
    try mcio.writePacket(mcv.H.SB, sw, handshake_packet, .{});

    // -- switch state
    current_state = switch (handshake_packet.handshake.next_state) {
        .status => .status,
        .login => .login,
    };

    clientbound_thread = try std.Thread.spawn(
        .{},
        handleClientbound_,
        .{ a, conn.stream, &cbw, &sbr, current_state, &alive, &alive_mutex, options },
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    while (true) {
        defer _ = arena.reset(.retain_capacity);
        var frame = try mcio.PacketFrame.read(cr, aa);
        try frame.write(sw);
        try sbw.flush();

        {
            alive_mutex.lock();
            defer alive_mutex.unlock();
            if (!alive) return;
        }

        switch (current_state) {
            inline else => |v| {
                const STS = switch (v) {
                    .handshake => unreachable,
                    .status => mcv.S,
                    .login => mcv.L,
                    .configuration => mcv.C,
                    .play => mcv.P,
                };
                const ST = STS.SB;

                const id = std.meta.intToEnum(STS.SBID, frame.id) catch continue;
                const pid = @unionInit(
                    PacketId,
                    "sb",
                    @unionInit(PacketId.Sb, @tagName(v), id),
                );
                if (!options.shown_packets.contains(pid)) continue;

                const show_contents = options.contents_packets.contains(pid);

                stdout_mutex.lock();
                defer stdout_mutex.unlock();
                defer stdout_b.flush() catch {};
                try stdout.print("{} c >s:{s}:0x{X}:({}): ", .{
                    fmt.fmtDurationSigned(@intCast(
                        time.nanoTimestamp() - options.start_time,
                    )),
                    @tagName(v),
                    frame.id,
                    frame.data.len,
                });
                if (!show_contents) {
                    try stdout.print("{s} ", .{@tagName(id)});
                }

                if (v != .status) {
                    const test_id = switch (v) {
                        .login => .login_acknowledged,
                        .configuration => .finish_configuration,
                        .play => .acknowledge_configuration,
                        else => unreachable,
                    };
                    if (id == test_id) {
                        current_state = switch (v) {
                            .login => .configuration,
                            .configuration => .play,
                            .play => .configuration,
                            else => unreachable,
                        };
                    }
                }

                var packet = frame.parse(ST, .{ .allocator = aa }) catch |e| {
                    if (show_contents) try stdout.print("{s}, ", .{@tagName(v)});
                    try stdout.print("parse error: \"{s}\"\n", .{@errorName(e)});
                    continue;
                };
                defer ST.deinit(&packet, .{ .allocator = aa });

                if (show_contents) {
                    try mcp.debugPrint(stdout, packet, 0);
                }

                try stdout.writeByte('\n');
            },
        }
    }
}

pub fn handleClientbound_(
    a: Allocator,
    stream: net.Stream,
    cbw: anytype,
    sbr: anytype,
    current_state_: CurrentState,
    alive: *bool,
    alive_mutex: *std.Thread.Mutex,
    options: Options,
) void {
    handleClientbound(
        a,
        stream,
        cbw,
        sbr,
        current_state_,
        alive,
        alive_mutex,
        options,
    ) catch {};
}
pub fn handleClientbound(
    a: Allocator,
    stream: net.Stream,
    cbw: anytype,
    sbr: anytype,
    current_state_: CurrentState,
    alive: *bool,
    alive_mutex: *std.Thread.Mutex,
    options: Options,
) !void {
    @setEvalBranchQuota(10_000);
    const sr = sbr.reader();
    const cw = cbw.writer();

    defer {
        alive_mutex.lock();
        if (alive.*) stream.close();
        alive.* = false;
        alive_mutex.unlock();
    }

    var dimension_heights = std.StringHashMapUnmanaged(mcp.chunk.UBlockY){};
    defer {
        var iter = dimension_heights.keyIterator();
        while (iter.next()) |key| {
            a.free(key.*);
        }
        dimension_heights.deinit(a);
    }
    var current_height: mcp.chunk.UBlockY = 384;

    var current_state: CurrentState = current_state_;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    while (true) {
        defer _ = arena.reset(.retain_capacity);
        var frame = try mcio.PacketFrame.read(sr, aa);
        try frame.write(cw);
        try cbw.flush();

        {
            alive_mutex.lock();
            defer alive_mutex.unlock();
            if (!alive.*) return;
        }

        switch (current_state) {
            inline else => |v| {
                const STS = switch (v) {
                    .handshake => unreachable,
                    .status => mcv.S,
                    .login => mcv.L,
                    .configuration => mcv.C,
                    .play => mcv.P,
                };
                const ST = STS.CB;
                const id = std.meta.intToEnum(STS.CBID, frame.id) catch continue;

                const pid = @unionInit(
                    PacketId,
                    "cb",
                    @unionInit(PacketId.Cb, @tagName(v), id),
                );
                if (!options.shown_packets.contains(pid)) continue;

                const show_contents = options.contents_packets.contains(pid);

                stdout_mutex.lock();
                defer stdout_mutex.unlock();
                try stdout.print("{} c< s:{s}:0x{X}:({}): ", .{
                    fmt.fmtDurationSigned(@intCast(
                        time.nanoTimestamp() - options.start_time,
                    )),
                    @tagName(v),
                    frame.id,
                    frame.data.len,
                });
                if (!show_contents) {
                    try stdout.print("{s} ", .{@tagName(id)});
                }
                defer stdout_b.flush() catch {};

                if (v != .status) {
                    const test_id = switch (v) {
                        .login => .login_success,
                        .configuration => .finish_configuration,
                        .play => .start_configuration,
                        else => unreachable,
                    };
                    if (id == test_id) {
                        current_state = switch (v) {
                            .login => .configuration,
                            .configuration => .play,
                            .play => .configuration,
                            else => unreachable,
                        };
                    }
                }

                const ctx = mcv.Context{
                    .allocator = aa,
                    .world = .{ .height = current_height },
                };
                var packet = frame.parse(ST, ctx) catch |e| {
                    if (show_contents) try stdout.print("{s}, ", .{@tagName(v)});
                    try stdout.print("parse error: \"{s}\"\n", .{@errorName(e)});
                    continue;
                };
                defer ST.deinit(&packet, ctx);

                if (ST == mcv.C.CB) {
                    // we need to keep track of dimension heights to properly handle
                    //     heightmaps and light levels
                    if (packet == .registry_data) {
                        if (packet.registry_data.dimension_type) |dimensions| {
                            for (dimensions.value) |dimension| {
                                const height = std.math.cast(
                                    mcp.chunk.UBlockY,
                                    dimension.element.height,
                                ) orelse continue;
                                if (dimension_heights.getPtr(dimension.name)) |d| {
                                    d.* = height;
                                } else {
                                    const duped_name = try a.dupe(u8, dimension.name);
                                    errdefer a.free(duped_name);
                                    try dimension_heights
                                        .putNoClobber(a, duped_name, height);
                                }
                            }
                        }
                    }
                } else if (ST == mcv.P.CB) {
                    if (packet == .login) {
                        if (dimension_heights
                            .get(packet.login.respawn.dimension_type)) |height|
                            current_height = height;
                    }
                }

                if (show_contents) {
                    try mcp.debugPrint(stdout, packet, 0);
                }

                try stdout.writeByte('\n');

                //if (v == .play) {
                //    if (id == .login) {
                //        var f = try std.fs.cwd().createFile("packet_login.bin", .{});
                //        defer f.close();
                //        try ST.write(f.writer(), packet);
                //    }
                //}

                //if (v == .configuration) {
                //    if (id == .registry_data) {
                //        {
                //            var f = try std.fs.cwd().createFile("packet.bin", .{});
                //            defer f.close();
                //            try ST.write(f.writer(), packet);
                //        }
                //        {
                //            var f = try std.fs.cwd().createFile("packet.txt", .{});
                //            defer f.close();
                //            try packet.registry_data.print(null, f.writer(), 0);
                //        }
                //        //return;
                //    }
                //}
            },
        }
    }
}
