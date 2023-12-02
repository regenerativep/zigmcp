const std = @import("std");
const io = std.io;
const mem = std.mem;
const Allocator = mem.Allocator;
const net = std.net;

const mcp = @import("mcp");
const mcio = mcp.packetio;
const mcv = mcp.vlatest;

pub fn main() !void {
    //@setEvalBranchQuota(10_000);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 25400);
    var server = net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(address);

    print("Listening on {}\n", .{address});

    while (true) {
        const conn = server.accept() catch |e| {
            std.log.err("Failed to accept connection: {any}", .{e});
            continue;
        };
        print("receiving connection from {}\n", .{conn.address});
        handleServerbound(gpa.allocator(), conn) catch |e| {
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
fn print(comptime fmt: [:0]const u8, args: anytype) void {
    stdout_mutex.lock();
    defer stdout_mutex.unlock();
    stdout.print(fmt, args) catch {};
    stdout_b.flush() catch {};
}

const CurrentState = enum {
    handshake,
    status,
    login,
    configuration,
    play,
};
pub fn handleServerbound(a: Allocator, conn: net.StreamServer.Connection) !void {
    @setEvalBranchQuota(10_000);

    var cbr = io.bufferedReader(conn.stream.reader());
    var cbw = io.bufferedWriter(conn.stream.writer());
    const cr = cbr.reader();

    // I'm _sure_ there's an amazing way to do this with atomics
    //     (however, I don't know atomics very well)
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
    var handshake_packet = try mcio.readHandshakePacket(mcv.H.SB, cr, a);
    defer mcv.H.SB.deinit(&handshake_packet, a);
    if (handshake_packet == .legacy) return;

    // -- connect to server
    const server_address = net.Address.initIp4(.{ 127, 0, 0, 1 }, 25565);
    var server_connection = try net.tcpConnectToAddress(server_address);
    defer server_connection.close();

    var sbr = io.bufferedReader(server_connection.reader());
    var sbw = io.bufferedWriter(server_connection.writer());
    const sw = sbw.writer();

    // -- pass along handshake to server
    try mcio.writePacket(mcv.H.SB, sw, handshake_packet);

    // -- switch state
    current_state = switch (handshake_packet.handshake.next_state) {
        .status => .status,
        .login => .login,
    };

    clientbound_thread = try std.Thread.spawn(
        .{},
        handleClientbound_,
        .{ a, conn.stream, &cbw, &sbr, current_state, &alive, &alive_mutex },
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    while (true) {
        //print("waiting for serverbound packet\n", .{});
        var frame = try mcio.PacketFrame.read(cr, aa);
        //defer frame.deinit(aa);
        //print("got serverbound packet\n", .{});
        try frame.write(sw);
        try sbw.flush();
        //print("passed along serverbound packet\n", .{});

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
                // yeah we also do a (safer) check in parse, whatever. we need this
                //     for state switching though
                const id: STS.SBID = @enumFromInt(frame.id);

                stdout_mutex.lock();
                defer stdout_mutex.unlock();
                try stdout.print(
                    "c->s:{s}:0x{X}:({}): {s} ",
                    .{ @tagName(v), frame.id, frame.data.len, @tagName(id) },
                );
                defer stdout_b.flush() catch {};

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

                var packet = frame.parse(ST, aa) catch |e| {
                    try stdout.print("parse error: \"{s}\"\n", .{@errorName(e)});
                    continue;
                };
                defer ST.deinit(&packet, aa);
                try stdout.writeByte('\n');
            },
        }
        _ = arena.reset(.retain_capacity);
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
) void {
    handleClientbound(
        a,
        stream,
        cbw,
        sbr,
        current_state_,
        alive,
        alive_mutex,
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

    var current_state: CurrentState = current_state_;

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    while (true) {
        //print("waiting for clientbound packet\n", .{});
        var frame = try mcio.PacketFrame.read(sr, aa);
        //defer frame.deinit(aa);
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
                const id: STS.CBID = @enumFromInt(frame.id);

                stdout_mutex.lock();
                defer stdout_mutex.unlock();
                try stdout.print(
                    "c<-s:{s}:0x{X}:({}): {s} ",
                    .{ @tagName(v), frame.id, frame.data.len, @tagName(id) },
                );
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

                //@compileLog(v);
                var packet = frame.parse(ST, aa) catch |e| {
                    try stdout.print("parse error: \"{s}\"\n", .{@errorName(e)});
                    continue;
                };
                defer ST.deinit(&packet, aa);
                try stdout.writeByte('\n');

                //if (v == .play) {
                //    if (id == .chunk_data_and_update_light) {
                //        try std.fs.cwd().writeFile("packet.bin", packet.chunk_data_and_update_light.data);
                //        return;
                //    }
                //}
            },
        }
        _ = arena.reset(.retain_capacity);
    }
}
