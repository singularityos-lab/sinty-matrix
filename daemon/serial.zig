const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto");

const Termios = extern struct {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [19]u8,
};

const tcgets: u32 = 0x5401;
const tcsets: u32 = 0x5402;
const tcflsh: u32 = 0x540b;
const cs8: u32 = 0o60;
const cread: u32 = 0o200;
const clocal: u32 = 0o4000;
const b115200: u32 = 0o10002;
const vtime = 5;
const vmin = 6;

pub const Port = struct {
    fd: i32,
    parser: proto.Parser = .{},

    pub fn open(path: [:0]const u8) !Port {
        const rc = linux.open(path, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.Open;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        var t: Termios = undefined;
        if (linux.errno(linux.ioctl(fd, tcgets, @intFromPtr(&t))) != .SUCCESS) return error.Termios;
        t.iflag = 0;
        t.oflag = 0;
        t.lflag = 0;
        t.cflag = cs8 | cread | clocal | b115200;
        t.cc[vmin] = 0;
        t.cc[vtime] = 0;
        if (linux.errno(linux.ioctl(fd, tcsets, @intFromPtr(&t))) != .SUCCESS) return error.Termios;
        _ = linux.ioctl(fd, tcflsh, 2);
        return .{ .fd = fd };
    }

    pub fn close(self: *Port) void {
        _ = linux.close(self.fd);
    }

    pub fn send(self: *Port, kind: proto.Kind, payload: []const u8) !void {
        var out: [proto.max_packet]u8 = undefined;
        var rest = proto.encode(&out, kind, payload);
        var spins: u32 = 0;
        while (rest.len > 0) {
            const rc = linux.write(self.fd, rest.ptr, rest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => rest = rest[rc..],
                .AGAIN => {
                    spins += 1;
                    if (spins > 200) return error.Stalled;
                    var p = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.OUT, .revents = 0 }};
                    _ = linux.poll(&p, 1, 10);
                },
                .INTR => {},
                else => return error.Write,
            }
        }
    }

    pub fn receive(self: *Port, sink: anytype) void {
        var buf: [256]u8 = undefined;
        while (true) {
            const rc = linux.read(self.fd, &buf, buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) return;
            for (buf[0..rc]) |b| {
                if (self.parser.push(b)) |p| sink.packet(p);
            }
        }
    }

    pub fn ask(self: *Port, timeout_ms: i32) ?proto.Info {
        const Catch = struct {
            info: ?proto.Info = null,
            pub fn packet(c: *@This(), p: proto.Packet) void {
                if (p.kind == .info and p.payload.len == @sizeOf(proto.Info)) c.info = std.mem.bytesToValue(proto.Info, p.payload[0..@sizeOf(proto.Info)]);
            }
        };
        var c: Catch = .{};
        self.receive(&c);
        self.send(.hello, &.{}) catch return null;
        var waited: i32 = 0;
        while (waited < timeout_ms and c.info == null) : (waited += 20) {
            var p = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&p, 1, 20);
            self.receive(&c);
        }
        return c.info;
    }
};

test "the kernel termios layout is 36 bytes" {
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(Termios));
}
