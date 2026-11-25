const std = @import("std");
const linux = std.os.linux;

pub const flag_input: u64 = 1 << 2;
pub const flag_output: u64 = 1 << 3;

const attr_flags: u32 = 1;
const attr_values: u32 = 2;

const Attribute = extern struct {
    id: u32,
    padding: u32 = 0,
    value: u64,
};

const ConfigAttribute = extern struct {
    attr: Attribute,
    mask: u64,
};

const Config = extern struct {
    flags: u64,
    num_attrs: u32,
    padding: [5]u32 = [_]u32{0} ** 5,
    attrs: [10]ConfigAttribute = std.mem.zeroes([10]ConfigAttribute),
};

const Request = extern struct {
    offsets: [64]u32,
    consumer: [32]u8,
    config: Config,
    num_lines: u32,
    event_buffer_size: u32,
    padding: [5]u32 = [_]u32{0} ** 5,
    fd: i32,
};

const Values = extern struct {
    bits: u64,
    mask: u64,
};

fn iowr(nr: u8, comptime T: type) u32 {
    return (3 << 30) | (@as(u32, @sizeOf(T)) << 16) | (0xb4 << 8) | nr;
}

const get_line = iowr(0x07, Request);
const set_config = iowr(0x0d, Config);
const get_values = iowr(0x0e, Values);
const set_values = iowr(0x0f, Values);

pub const Failure = struct {
    op: []const u8 = "",
    errno: linux.E = .SUCCESS,
};

pub var last_failure: Failure = .{};

fn ioctl(fd: i32, req: u32, arg: *anyopaque, op: []const u8) !void {
    while (true) {
        const rc = linux.ioctl(fd, req, @intFromPtr(arg));
        switch (linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => |e| {
                last_failure = .{ .op = op, .errno = e };
                return error.Ioctl;
            },
        }
    }
}

pub fn findChip(controller: []const u8) !i32 {
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        var sys: [64]u8 = undefined;
        const link = try std.fmt.bufPrintZ(&sys, "/sys/bus/gpio/devices/gpiochip{d}", .{i});
        var target: [512]u8 = undefined;
        const rc = linux.readlink(link, &target, target.len);
        if (linux.errno(rc) != .SUCCESS) continue;
        const path = target[0..rc];
        var needle: [128]u8 = undefined;
        const want = try std.fmt.bufPrint(&needle, "/{s}/", .{controller});
        if (std.mem.indexOf(u8, path, want) == null) continue;
        var dev: [32]u8 = undefined;
        const p = try std.fmt.bufPrintZ(&dev, "/dev/gpiochip{d}", .{i});
        const fd = linux.open(p, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return error.Open;
        return @intCast(fd);
    }
    return error.NoChip;
}

pub const Lines = struct {
    fd: i32,
    count: u6,
    outputs: u64,
    values: u64,

    pub fn request(chip: i32, offsets: []const u32, initial: u64) !Lines {
        var req = std.mem.zeroes(Request);
        for (offsets, 0..) |o, i| req.offsets[i] = o;
        @memcpy(req.consumer[0.."sinty-matrixd".len], "sinty-matrixd");
        req.num_lines = @intCast(offsets.len);
        const all: u64 = (@as(u64, 1) << @intCast(offsets.len)) - 1;
        req.config = .{ .flags = flag_output, .num_attrs = 1 };
        req.config.attrs[0] = .{ .attr = .{ .id = attr_values, .value = initial }, .mask = all };
        try ioctl(chip, get_line, &req, "request the lines");
        return .{ .fd = req.fd, .count = @intCast(offsets.len), .outputs = all, .values = initial };
    }

    pub fn release(self: *Lines) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    pub fn setDirection(self: *Lines, line: u6, output: bool) !void {
        const bit = @as(u64, 1) << line;
        if (output == (self.outputs & bit != 0)) return;
        if (output) self.outputs |= bit else self.outputs &= ~bit;
        const all: u64 = (@as(u64, 1) << self.count) - 1;
        var cfg: Config = .{ .flags = flag_output, .num_attrs = 2 };
        cfg.attrs[0] = .{ .attr = .{ .id = attr_flags, .value = flag_input }, .mask = all & ~self.outputs };
        cfg.attrs[1] = .{ .attr = .{ .id = attr_values, .value = self.values }, .mask = self.outputs };
        if (cfg.attrs[0].mask == 0) {
            cfg.attrs[0] = cfg.attrs[1];
            cfg.num_attrs = 1;
        }
        try ioctl(self.fd, set_config, &cfg, if (output) "drive swdio" else "release swdio");
    }

    pub fn set(self: *Lines, mask: u64, bits: u64) !void {
        self.values = (self.values & ~mask) | (bits & mask);
        var v: Values = .{ .bits = self.values, .mask = mask & self.outputs };
        try ioctl(self.fd, set_values, &v, "set the lines");
    }

    pub fn get(self: *Lines, line: u6) !bool {
        var v: Values = .{ .bits = 0, .mask = @as(u64, 1) << line };
        try ioctl(self.fd, get_values, &v, "read swdio");
        return v.bits & v.mask != 0;
    }
};

test "the uapi structs keep the kernel sizes" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Attribute));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(ConfigAttribute));
    try std.testing.expectEqual(@as(usize, 272), @sizeOf(Config));
    try std.testing.expectEqual(@as(usize, 592), @sizeOf(Request));
    try std.testing.expectEqual(@as(u32, 0xc250b407), get_line);
}
