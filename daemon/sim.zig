const std = @import("std");
const swd = @import("swd.zig");
const stm32u5 = @import("stm32u5.zig");

const Target = struct {
    const State = enum { idle, req, trn, ack, rdata, wtrn, wdata };

    gpa: std.mem.Allocator,
    mem: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    dpidr: u32 = stm32u5.expected_dpidr,
    state: State = .idle,
    ones: u32 = 0,
    req: u8 = 0,
    nbits: u8 = 0,
    idx: u8 = 0,
    value: u32 = 0,
    out: bool = true,
    driving: bool = false,
    ack: u3 = 0b001,
    ctrl: u32 = 0,
    select: u32 = 0,
    rdbuff: u32 = 0,
    ap_buf: u32 = 0,
    csw: u32 = 0x2300_0040,
    tar: u32 = 0,
    halted: bool = false,
    locked: bool = true,
    key_step: u8 = 0,
    nscr: u32 = 1 << 31,
    flash_writes: u32 = 0,

    fn load(self: *Target, addr: u32) u32 {
        if (addr == 0x4002_2020) return 0;
        if (addr == 0x4002_2028) return self.nscr;
        if (addr == 0xe000_edf0) return if (self.halted) 1 << 17 else 0;
        if (self.mem.get(addr)) |v| return v;
        return if (addr >= 0x0800_0000 and addr < 0x0820_0000) 0xffff_ffff else 0;
    }

    fn store(self: *Target, addr: u32, v: u32) void {
        switch (addr) {
            0x4002_2008 => {
                if (self.key_step == 0 and v == 0x4567_0123) {
                    self.key_step = 1;
                } else if (self.key_step == 1 and v == 0xcdef_89ab) {
                    self.locked = false;
                    self.nscr &= ~@as(u32, 1 << 31);
                    self.key_step = 0;
                } else self.key_step = 0;
            },
            0x4002_2028 => {
                if (self.locked) return;
                self.nscr = v;
                if (v & (1 << 31) != 0) self.locked = true;
                if (v & (1 << 16) != 0 and v & 2 != 0) {
                    const page = (v >> 3) & 0x7f;
                    var a: u32 = 0x0800_0000 + page * 8192;
                    while (a < 0x0800_0000 + (page + 1) * 8192) : (a += 4) _ = self.mem.remove(a);
                }
            },
            0xe000_edf0 => self.halted = v & 2 != 0 and v >> 16 == 0xa05f,
            else => {
                if (addr >= 0x0800_0000 and addr < 0x0820_0000) {
                    if (self.locked or self.nscr & 1 == 0) return;
                    self.flash_writes += 1;
                }
                self.mem.put(self.gpa, addr, v) catch unreachable;
            },
        }
    }

    fn readReg(self: *Target, ap: bool, addr: u4) u32 {
        if (ap) {
            const prev = self.ap_buf;
            self.ap_buf = switch (addr) {
                0x0 => self.csw,
                0x4 => self.tar,
                0xc => self.load(self.tar),
                else => 0,
            };
            self.rdbuff = self.ap_buf;
            return prev;
        }
        return switch (addr) {
            0x0 => self.dpidr,
            0x4 => self.ctrl | ((self.ctrl & 0x5000_0000) << 1),
            0xc => self.rdbuff,
            else => 0,
        };
    }

    fn writeReg(self: *Target, ap: bool, addr: u4, v: u32) void {
        if (ap) {
            switch (addr) {
                0x0 => self.csw = v,
                0x4 => self.tar = v,
                0xc => self.store(self.tar, v),
                else => {},
            }
            return;
        }
        switch (addr) {
            0x4 => self.ctrl = v,
            0x8 => self.select = v,
            else => {},
        }
    }

    fn edge(self: *Target, host: bool, host_drives: bool) void {
        if (host_drives and host) self.ones += 1 else self.ones = 0;
        if (self.ones >= 50) {
            self.state = .idle;
            self.driving = false;
            return;
        }
        switch (self.state) {
            .idle => if (host_drives and host) {
                self.state = .req;
                self.req = 1;
                self.nbits = 1;
            },
            .req => {
                if (host) self.req |= @as(u8, 1) << @intCast(self.nbits);
                self.nbits += 1;
                if (self.nbits < 8) return;
                const r = self.req;
                const ap = r & 2 != 0;
                const rnw = r & 4 != 0;
                const parity: u8 = @popCount(r & 0x1e) & 1;
                if (r & 0x40 != 0 or r & 0x80 == 0 or parity != (r >> 5) & 1) {
                    self.state = .idle;
                    return;
                }
                if (rnw) self.value = self.readReg(ap, @intCast((r >> 1) & 0xc));
                self.state = .trn;
            },
            .trn => {
                self.driving = true;
                self.out = self.ack & 1 != 0;
                self.idx = 1;
                self.state = .ack;
            },
            .ack => {
                if (self.idx < 3) {
                    self.out = (self.ack >> @intCast(self.idx)) & 1 != 0;
                    self.idx += 1;
                    return;
                }
                if (self.req & 4 != 0) {
                    self.out = self.value & 1 != 0;
                    self.idx = 1;
                    self.state = .rdata;
                } else {
                    self.driving = false;
                    self.state = .wtrn;
                }
            },
            .rdata => {
                if (self.idx < 32) {
                    self.out = (self.value >> @intCast(self.idx)) & 1 != 0;
                } else if (self.idx == 32) {
                    self.out = @popCount(self.value) & 1 != 0;
                } else {
                    self.driving = false;
                    self.state = .idle;
                }
                self.idx += 1;
            },
            .wtrn => {
                self.value = 0;
                self.idx = 0;
                self.state = .wdata;
            },
            .wdata => {
                if (self.idx < 32) {
                    if (host) self.value |= @as(u32, 1) << @intCast(self.idx);
                    self.idx += 1;
                    return;
                }
                if (@popCount(self.value) & 1 == @intFromBool(host)) {
                    const r = self.req;
                    self.writeReg(r & 2 != 0, @intCast((r >> 1) & 0xc), self.value);
                }
                self.state = .idle;
            },
        }
    }
};

const Pins = struct {
    target: *Target,
    values: u64 = swd.rst_bit,
    host_drives: bool = true,

    pub fn set(self: *Pins, mask: u64, bits: u64) !void {
        const before = self.values;
        self.values = (self.values & ~mask) | (bits & mask);
        if (before & swd.clk_bit == 0 and self.values & swd.clk_bit != 0) {
            self.target.edge(self.values & swd.dio_bit != 0, self.host_drives);
        }
    }

    pub fn get(self: *Pins, _: u6) !bool {
        return if (self.target.driving) self.target.out else true;
    }

    pub fn setDirection(self: *Pins, _: u6, out: bool) !void {
        self.host_drives = out;
    }
};

const SimLink = swd.Link(Pins);

test "the flasher programs and verifies an image on a simulated STM32U5" {
    var t: Target = .{ .gpa = std.testing.allocator };
    defer t.mem.deinit(std.testing.allocator);
    var link: SimLink = .{ .pins = .{ .target = &t } };
    var image: [9000]u8 = undefined;
    for (&image, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    try t.mem.put(std.testing.allocator, 0x0800_2000, 0x1234_5678);
    try stm32u5.flash(&link, &image);
    try std.testing.expect(t.locked);
    try std.testing.expect(!t.halted);
    try std.testing.expectEqual(@as(u32, (9000 + 15) / 16 * 4), t.flash_writes);
    var off: u32 = 0;
    while (off < image.len) : (off += 4) {
        var word = [_]u8{0xff} ** 4;
        const n = @min(4, image.len - off);
        @memcpy(word[0..n], image[off..][0..n]);
        try std.testing.expectEqual(std.mem.readInt(u32, &word, .little), t.load(0x0800_0000 + off));
    }
}

test "a chip with another debug id is never written" {
    var t: Target = .{ .gpa = std.testing.allocator, .dpidr = 0x2ba0_1477 };
    defer t.mem.deinit(std.testing.allocator);
    var link: SimLink = .{ .pins = .{ .target = &t } };
    try std.testing.expectError(error.BadIdentity, stm32u5.flash(&link, &[_]u8{1} ** 64));
    try std.testing.expectEqual(@as(u32, 0), t.flash_writes);
}

test "a fault answer stops the transfer" {
    var t: Target = .{ .gpa = std.testing.allocator, .ack = 0b100 };
    defer t.mem.deinit(std.testing.allocator);
    var link: SimLink = .{ .pins = .{ .target = &t } };
    try std.testing.expectError(error.Fault, link.connect());
}

test "a flash that fails after the halt leaves the controller running" {
    var t: Target = .{ .gpa = std.testing.allocator };
    defer t.mem.deinit(std.testing.allocator);
    var link: SimLink = .{ .pins = .{ .target = &t } };
    const too_big = try std.testing.allocator.alloc(u8, 128 * 8 * 1024 + 1);
    defer std.testing.allocator.free(too_big);
    try std.testing.expectError(error.TooLarge, stm32u5.flash(&link, too_big));
    try std.testing.expect(!t.halted);
    try std.testing.expect(t.locked);
    try std.testing.expectEqual(@as(u32, 0), t.flash_writes);
}
