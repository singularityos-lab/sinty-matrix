const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto");

const socket_path = "/run/sinty-matrix/socket";

fn out(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    _ = linux.write(1, s.ptr, s.len);
}

fn usage() noreturn {
    out(
        \\usage: sinty-matrixctl info
        \\       sinty-matrixctl clear
        \\       sinty-matrixctl brightness 0-7
        \\       sinty-matrixctl fill 0-7
        \\       sinty-matrixctl levels
        \\       sinty-matrixctl demo [seconds]
    , .{});
    std.process.exit(2);
}

fn open() i32 {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) fail("socket");
    const fd: i32 = @intCast(rc);
    var addr = linux.sockaddr.un{ .path = [_]u8{0} ** 108 };
    @memcpy(addr.path[0..socket_path.len], socket_path);
    if (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un))) != .SUCCESS) fail(socket_path ++ " is not reachable, is sinty-matrixd running?");
    return fd;
}

fn fail(msg: []const u8) noreturn {
    out("sinty-matrixctl: {s}", .{msg});
    std.process.exit(1);
}

fn send(fd: i32, kind: proto.Kind, payload: []const u8) void {
    var buf: [1 + 1024]u8 = undefined;
    buf[0] = @intFromEnum(kind);
    @memcpy(buf[1..][0..payload.len], payload);
    if (linux.errno(linux.sendto(fd, &buf, 1 + payload.len, linux.MSG.NOSIGNAL, null, 0)) != .SUCCESS) fail("send");
}

fn info(fd: i32) proto.Info {
    send(fd, .hello, &.{});
    var buf: [64]u8 = undefined;
    const rc = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
    if (linux.errno(rc) != .SUCCESS or rc < 1) fail("no answer");
    if (rc < 1 + @sizeOf(proto.Info)) fail("the service runs, but the matrix controller does not answer");
    return std.mem.bytesToValue(proto.Info, buf[1..][0..@sizeOf(proto.Info)]);
}

fn level(arg: ?[:0]const u8) u8 {
    const a = arg orelse usage();
    const v = std.fmt.parseInt(u8, a, 10) catch usage();
    if (v > 7) usage();
    return v;
}

fn sleepMs(ms: u64) void {
    const ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const argv = try init.args.toSlice(arena_state.allocator());
    if (argv.len < 2) usage();
    const cmd = argv[1];
    const arg: ?[:0]const u8 = if (argv.len > 2) argv[2] else null;
    const fd = open();
    const m = info(fd);
    const n = @as(usize, m.width) * m.height;
    var px: [1024]u8 = undefined;
    if (n > px.len) fail("matrix too large");
    if (std.mem.eql(u8, cmd, "info")) {
        out("{d}x{d}, {d} levels, protocol {d}, firmware {d}", .{ m.width, m.height, m.levels, m.proto, m.firmware });
    } else if (std.mem.eql(u8, cmd, "clear")) {
        send(fd, .clear, &.{});
    } else if (std.mem.eql(u8, cmd, "brightness")) {
        send(fd, .brightness, &.{level(arg)});
    } else if (std.mem.eql(u8, cmd, "fill")) {
        @memset(px[0..n], level(arg));
        send(fd, .frame, px[0..n]);
    } else if (std.mem.eql(u8, cmd, "levels")) {
        for (0..m.height) |y| for (0..m.width) |x| {
            px[y * m.width + x] = @intCast((x * 8) / m.width);
        };
        send(fd, .frame, px[0..n]);
    } else if (std.mem.eql(u8, cmd, "demo")) {
        const seconds = if (arg) |a| std.fmt.parseInt(u32, a, 10) catch usage() else 20;
        var t: u32 = 0;
        while (t < seconds * 25) : (t += 1) {
            for (0..m.height) |y| for (0..m.width) |x| {
                const d = (x + y + t) % (@as(usize, m.width) + m.height);
                px[y * m.width + x] = if (d < 8) @intCast(7 - d) else 0;
            };
            send(fd, .frame, px[0..n]);
            sleepMs(40);
        }
    } else usage();
}
