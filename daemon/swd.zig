const std = @import("std");
const gpio = @import("gpio.zig");

pub const clk: u6 = 0;
pub const dio: u6 = 1;
pub const rst: u6 = 2;

pub const clk_bit: u64 = 1 << clk;
pub const dio_bit: u64 = 1 << dio;
pub const rst_bit: u64 = 1 << rst;

const ack_ok: u3 = 0b001;
const ack_wait: u3 = 0b010;
const ack_fault: u3 = 0b100;

pub const dp_idr: u4 = 0x0;
pub const dp_abort: u4 = 0x0;
pub const dp_ctrl: u4 = 0x4;
pub const dp_select: u4 = 0x8;
pub const dp_rdbuff: u4 = 0xc;

pub const ap_csw: u4 = 0x0;
pub const ap_tar: u4 = 0x4;
pub const ap_drw: u4 = 0xc;

pub const Error = error{ Fault, NoAck, Parity, Timeout, Ioctl };

pub fn request(ap: bool, rnw: bool, addr: u4) u8 {
    const a2: u8 = (addr >> 2) & 1;
    const a3: u8 = (addr >> 3) & 1;
    const apb: u8 = @intFromBool(ap);
    const rb: u8 = @intFromBool(rnw);
    const parity = (apb + rb + a2 + a3) & 1;
    return 0x81 | (apb << 1) | (rb << 2) | (a2 << 3) | (a3 << 4) | (parity << 5);
}

pub fn Link(comptime Pins: type) type {
    return struct {
        const Self = @This();

        pins: Pins,

        pub fn holdReset(self: *Self, held: bool) Error!void {
            self.pins.set(rst_bit, if (held) 0 else rst_bit) catch return error.Ioctl;
        }

        fn bitOut(self: *Self, b: bool) Error!void {
            self.pins.set(clk_bit | dio_bit, if (b) dio_bit else 0) catch return error.Ioctl;
            self.pins.set(clk_bit, clk_bit) catch return error.Ioctl;
        }

        fn bitIn(self: *Self) Error!bool {
            self.pins.set(clk_bit, 0) catch return error.Ioctl;
            const v = self.pins.get(dio) catch return error.Ioctl;
            self.pins.set(clk_bit, clk_bit) catch return error.Ioctl;
            return v;
        }

        fn drive(self: *Self, out: bool) Error!void {
            self.pins.setDirection(dio, out) catch return error.Ioctl;
        }

        fn bitsOut(self: *Self, value: u64, n: u7) Error!void {
            var i: u7 = 0;
            while (i < n) : (i += 1) try self.bitOut((value >> @intCast(i)) & 1 == 1);
        }

        fn turnaround(self: *Self) Error!void {
            _ = try self.bitIn();
        }

        pub fn lineReset(self: *Self) Error!void {
            try self.drive(true);
            try self.bitsOut(std.math.maxInt(u64), 56);
        }

        pub fn connect(self: *Self) Error!u32 {
            try self.lineReset();
            try self.bitsOut(0xe79e, 16);
            try self.lineReset();
            try self.bitsOut(0, 8);
            return self.read(false, dp_idr);
        }

        fn ack(self: *Self) Error!u3 {
            var a: u3 = 0;
            var i: u2 = 0;
            while (i < 3) : (i += 1) {
                if (try self.bitIn()) a |= @as(u3, 1) << i;
            }
            return a;
        }

        fn failed(a: u3) Error {
            return if (a == ack_fault) error.Fault else error.NoAck;
        }

        pub fn read(self: *Self, ap: bool, addr: u4) Error!u32 {
            var tries: u32 = 0;
            while (tries < 100) : (tries += 1) {
                try self.drive(true);
                try self.bitsOut(request(ap, true, addr), 8);
                try self.drive(false);
                try self.turnaround();
                const a = try self.ack();
                if (a == ack_ok) {
                    var v: u32 = 0;
                    var i: u6 = 0;
                    while (i < 32) : (i += 1) {
                        if (try self.bitIn()) v |= @as(u32, 1) << @intCast(i);
                    }
                    const p = try self.bitIn();
                    try self.turnaround();
                    try self.drive(true);
                    try self.bitsOut(0, 8);
                    if (@popCount(v) & 1 != @intFromBool(p)) return error.Parity;
                    return v;
                }
                try self.turnaround();
                try self.drive(true);
                try self.bitsOut(0, 8);
                if (a != ack_wait) return failed(a);
            }
            return error.Timeout;
        }

        pub fn write(self: *Self, ap: bool, addr: u4, value: u32) Error!void {
            var tries: u32 = 0;
            while (tries < 100) : (tries += 1) {
                try self.drive(true);
                try self.bitsOut(request(ap, false, addr), 8);
                try self.drive(false);
                try self.turnaround();
                const a = try self.ack();
                try self.turnaround();
                try self.drive(true);
                if (a == ack_ok) {
                    try self.bitsOut(value, 32);
                    try self.bitOut(@popCount(value) & 1 == 1);
                    try self.bitsOut(0, 8);
                    return;
                }
                try self.bitsOut(0, 8);
                if (a != ack_wait) return failed(a);
            }
            return error.Timeout;
        }
    };
}

pub const Swd = struct {
    link: Link(gpio.Lines),

    pub fn open(chip: i32, swclk: u32, swdio: u32, reset: u32) !Swd {
        const lines = try gpio.Lines.request(chip, &.{ swclk, swdio, reset }, rst_bit);
        return .{ .link = .{ .pins = lines } };
    }

    pub fn close(self: *Swd) void {
        self.link.pins.release();
    }
};

pub fn Mem(comptime L: type) type {
    return struct {
        const Self = @This();

        link: *L,
        tar: ?u32 = null,

        pub fn init(link: *L) Error!Self {
            try link.write(false, dp_abort, 0x1e);
            try link.write(false, dp_ctrl, 0x5000_0000);
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                if (try link.read(false, dp_ctrl) & 0xa000_0000 == 0xa000_0000) break;
            } else return error.Timeout;
            try link.write(false, dp_select, 0);
            _ = try link.read(true, ap_csw);
            const csw = (try link.read(false, dp_rdbuff) & ~@as(u32, 0x37)) | 0x02;
            try link.write(true, ap_csw, csw);
            return .{ .link = link };
        }

        pub fn write32(self: *Self, addr: u32, value: u32) Error!void {
            if (self.tar != addr) try self.link.write(true, ap_tar, addr);
            self.tar = addr;
            try self.link.write(true, ap_drw, value);
        }

        pub fn read32(self: *Self, addr: u32) Error!u32 {
            if (self.tar != addr) try self.link.write(true, ap_tar, addr);
            self.tar = addr;
            _ = try self.link.read(true, ap_drw);
            return self.link.read(false, dp_rdbuff);
        }
    };
}

test "request bytes match the ADIv5 encoding" {
    try std.testing.expectEqual(@as(u8, 0xa5), request(false, true, dp_idr));
    try std.testing.expectEqual(@as(u8, 0xa9), request(false, false, dp_ctrl));
    try std.testing.expectEqual(@as(u8, 0x8d), request(false, true, dp_ctrl));
    try std.testing.expectEqual(@as(u8, 0xbd), request(false, true, dp_rdbuff));
    try std.testing.expectEqual(@as(u8, 0x9f), request(true, true, ap_drw));
}
