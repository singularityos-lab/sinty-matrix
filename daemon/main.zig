const std = @import("std");
const linux = std.os.linux;
const proto = @import("proto");
const build_options = @import("build_options");
const gpio = @import("gpio.zig");
const swd = @import("swd.zig");
const stm32u5 = @import("stm32u5.zig");
const serial = @import("serial.zig");

const profiles = "/usr/share/sinty-matrix/devices";
const state_dir = "/var/lib/sinty-matrix";
const attempts_path = state_dir ++ "/flash-attempts";
const run_dir = "/run/sinty-matrix";
const socket_path = run_dir ++ "/socket";
const client_group = "singularity-session";
const max_attempts = 3;
const max_clients = 16;
const keepalive_ms = 5000;

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "sinty-matrixd: " ++ fmt ++ "\n", args) catch return;
    _ = linux.write(2, s.ptr, s.len);
}

fn readFile(path: [:0]const u8, buf: []u8) ?[]u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = linux.read(fd, buf[n..].ptr, buf.len - n);
        if (linux.errno(r) != .SUCCESS or r == 0) break;
        n += r;
    }
    return buf[0..n];
}

fn writeFile(path: [:0]const u8, data: []const u8) void {
    const rc = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    _ = linux.write(fd, data.ptr, data.len);
    _ = linux.close(fd);
}

pub const Profile = struct {
    serial: [:0]const u8 = "",
    gpio: []const u8 = "",
    swclk: u32 = 0,
    swdio: u32 = 0,
    reset: u32 = 0,
    firmware: [:0]const u8 = "",
};

pub fn parseProfile(arena: std.mem.Allocator, text: []const u8) !Profile {
    var p: Profile = .{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Malformed;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, key, "serial")) {
            p.serial = try arena.dupeZ(u8, value);
        } else if (std.mem.eql(u8, key, "gpio")) {
            p.gpio = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "swclk")) {
            p.swclk = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "swdio")) {
            p.swdio = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "reset")) {
            p.reset = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, key, "firmware")) {
            p.firmware = try arena.dupeZ(u8, value);
        }
    }
    if (p.serial.len == 0) return error.Malformed;
    return p;
}

fn findProfile(arena: std.mem.Allocator) ?Profile {
    var compat: [1024]u8 = undefined;
    const list = readFile("/proc/device-tree/compatible", &compat) orelse return null;
    var it = std.mem.tokenizeScalar(u8, list, 0);
    while (it.next()) |name| {
        const path = std.fmt.allocPrintSentinel(arena, "{s}/{s}.conf", .{ profiles, name }, 0) catch return null;
        var buf: [2048]u8 = undefined;
        const text = readFile(path, &buf) orelse continue;
        return parseProfile(arena, text) catch |err| {
            log("{s}: {s}", .{ path, @errorName(err) });
            return null;
        };
    }
    return null;
}

fn attempts() u32 {
    var buf: [16]u8 = undefined;
    const text = readFile(attempts_path, &buf) orelse return 0;
    return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch 0;
}

fn setAttempts(n: u32) void {
    _ = linux.mkdir(state_dir, 0o755);
    var buf: [16]u8 = undefined;
    writeFile(attempts_path, std.fmt.bufPrint(&buf, "{d}\n", .{n}) catch return);
}

fn flash(arena: std.mem.Allocator, p: Profile) !void {
    if (p.gpio.len == 0 or p.firmware.len == 0) return error.NoFlasher;
    const buf = try arena.alloc(u8, 1 << 20);
    const image = readFile(p.firmware, buf) orelse return error.NoImage;
    const chip = try gpio.findChip(p.gpio);
    defer _ = linux.close(chip);
    var link = try swd.Swd.open(chip, p.swclk, p.swdio, p.reset);
    defer link.close();
    try stm32u5.flash(&link.link, image);
}

fn current(info: ?proto.Info) bool {
    const i = info orelse return false;
    return i.proto == proto.version and i.firmware == build_options.firmware_version;
}

fn bringUp(arena: std.mem.Allocator, p: Profile, port: *serial.Port) ?proto.Info {
    const first = port.ask(500);
    if (current(first)) {
        setAttempts(0);
        return first;
    }
    const n = attempts();
    if (n >= max_attempts) {
        log("{d} flash attempts did not bring up firmware {d}; remove {s} to try again", .{ n, build_options.firmware_version, attempts_path });
        return null;
    }
    setAttempts(n + 1);
    log("flashing the matrix controller with firmware {d}", .{build_options.firmware_version});
    flash(arena, p) catch |err| {
        log("flash failed: {s}", .{@errorName(err)});
        return null;
    };
    var tries: u32 = 0;
    while (tries < 10) : (tries += 1) {
        const info = port.ask(300);
        if (current(info)) {
            setAttempts(0);
            return info;
        }
    }
    log("the controller did not answer after flashing", .{});
    return null;
}

fn groupId(name: []const u8) ?u32 {
    var buf: [8192]u8 = undefined;
    const text = readFile("/etc/group", &buf) orelse return null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ':');
        const n = f.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        _ = f.next();
        return std.fmt.parseInt(u32, f.next() orelse return null, 10) catch null;
    }
    return null;
}

fn listen() !i32 {
    _ = linux.mkdir(run_dir, 0o755);
    _ = linux.unlink(socket_path);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(rc) != .SUCCESS) return error.Socket;
    const fd: i32 = @intCast(rc);
    var addr = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    @memcpy(addr.path[0..socket_path.len], socket_path);
    if (linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.Bind;
    if (groupId(client_group)) |gid| _ = linux.chown(socket_path, 0, gid);
    _ = linux.chmod(socket_path, 0o660);
    if (linux.errno(linux.listen(fd, 8)) != .SUCCESS) return error.Listen;
    return fd;
}

const Device = struct {
    port: serial.Port,
    info: proto.Info,
    frame: [proto.max_payload]u8 = undefined,
    have_frame: bool = false,
    brightness: ?u8 = null,

    fn pixels(self: *const Device) usize {
        return @as(usize, self.info.width) * self.info.height;
    }

    fn apply(self: *Device, kind: proto.Kind, payload: []const u8) void {
        switch (kind) {
            .frame => {
                if (payload.len != self.pixels()) return;
                @memcpy(self.frame[0..payload.len], payload);
                self.have_frame = true;
                self.port.send(.frame, payload) catch |err| log("frame: {s}", .{@errorName(err)});
            },
            .brightness => {
                if (payload.len != 1) return;
                self.brightness = payload[0];
                self.port.send(.brightness, payload) catch {};
            },
            .clear => {
                self.have_frame = false;
                self.port.send(.clear, &.{}) catch {};
            },
            else => {},
        }
    }

    fn refresh(self: *Device) void {
        if (self.brightness) |b| self.port.send(.brightness, &.{b}) catch {};
        if (self.have_frame) self.port.send(.frame, self.frame[0..self.pixels()]) catch {};
    }

    pub fn packet(_: *Device, _: proto.Packet) void {}
};

fn serve(dev: ?*Device) !void {
    const lfd = try listen();
    var fds: [2 + max_clients]linux.pollfd = undefined;
    var clients: usize = 0;
    while (true) {
        fds[0] = .{ .fd = lfd, .events = linux.POLL.IN, .revents = 0 };
        fds[1] = .{ .fd = if (dev) |d| d.port.fd else -1, .events = linux.POLL.IN, .revents = 0 };
        const n = linux.poll(&fds, 2 + clients, keepalive_ms);
        if (linux.errno(n) != .SUCCESS) continue;
        if (n == 0) {
            if (dev) |d| d.refresh();
            continue;
        }
        if (fds[1].revents != 0) {
            if (dev) |d| d.port.receive(d);
        }
        var i: usize = 2;
        while (i < 2 + clients) {
            if (fds[i].revents == 0) {
                i += 1;
                continue;
            }
            var buf: [1 + proto.max_payload]u8 = undefined;
            const r = linux.recvfrom(fds[i].fd, &buf, buf.len, 0, null, null);
            if (linux.errno(r) != .SUCCESS or r == 0) {
                _ = linux.close(fds[i].fd);
                fds[i] = fds[1 + clients];
                clients -= 1;
                continue;
            }
            const kind: proto.Kind = @enumFromInt(buf[0]);
            if (kind == .hello) {
                var reply: [1 + @sizeOf(proto.Info)]u8 = undefined;
                reply[0] = @intFromEnum(proto.Kind.info);
                var len: usize = 1;
                if (dev) |d| {
                    @memcpy(reply[1..], std.mem.asBytes(&d.info));
                    len = reply.len;
                }
                _ = linux.sendto(fds[i].fd, &reply, len, linux.MSG.NOSIGNAL, null, 0);
            } else if (dev) |d| d.apply(kind, buf[1..r]);
            i += 1;
        }
        if (fds[0].revents != 0 and clients < max_clients) {
            const c = linux.accept4(lfd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(c) == .SUCCESS) {
                fds[2 + clients] = .{ .fd = @intCast(c), .events = linux.POLL.IN, .revents = 0 };
                clients += 1;
            }
        }
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try init.args.toSlice(arena);
    const p = if (argv.len > 1) explicit: {
        const path = argv[1];
        var buf: [2048]u8 = undefined;
        const text = readFile(path, &buf) orelse {
            log("{s}: cannot read", .{path});
            return error.NoProfile;
        };
        break :explicit try parseProfile(arena, text);
    } else findProfile(arena) orelse {
        log("this device has no LED matrix", .{});
        return;
    };
    var port = serial.Port.open(p.serial) catch |err| {
        log("{s}: {s}", .{ p.serial, @errorName(err) });
        return err;
    };
    var device: Device = undefined;
    var dev: ?*Device = null;
    if (bringUp(arena, p, &port)) |info| {
        device = .{ .port = port, .info = info };
        dev = &device;
        log("matrix {d}x{d}, {d} levels, firmware {d}", .{ info.width, info.height, info.levels, info.firmware });
    }
    try serve(dev);
}

test "a device profile parses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try parseProfile(arena_state.allocator(),
        \\# UNO Q
        \\serial=/dev/ttyHS1
        \\gpio = 500000.pinctrl
        \\swclk=26
        \\swdio=25
        \\reset=38
        \\firmware=/usr/share/sinty-matrix/uno-q.bin
    );
    try std.testing.expectEqualStrings("/dev/ttyHS1", p.serial);
    try std.testing.expectEqualStrings("500000.pinctrl", p.gpio);
    try std.testing.expectEqual(@as(u32, 26), p.swclk);
    try std.testing.expectEqual(@as(u32, 38), p.reset);
}

test {
    _ = @import("sim.zig");
    _ = gpio;
    _ = swd;
    _ = serial;
}
