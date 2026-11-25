const std = @import("std");
const swd = @import("swd.zig");

const dhcsr: u32 = 0xe000_edf0;
const demcr: u32 = 0xe000_edfc;
const aircr: u32 = 0xe000_ed0c;
const dbg_key: u32 = 0xa05f_0000;
const s_halt: u32 = 1 << 17;

const flash_base: u32 = 0x0800_0000;
const page_size: u32 = 8 * 1024;
const pages_per_bank: u32 = 128;

const fl = 0x4002_2000;
const nskeyr: u32 = fl + 0x08;
const nssr: u32 = fl + 0x20;
const nscr: u32 = fl + 0x28;

const sr_bsy: u32 = 1 << 16;
const sr_wdw: u32 = 1 << 17;
const sr_errors: u32 = 0b1111_1010 | (1 << 13);
const sr_clear: u32 = sr_errors | 1;

const cr_pg: u32 = 1 << 0;
const cr_per: u32 = 1 << 1;
const cr_strt: u32 = 1 << 16;
const cr_lock: u32 = 1 << 31;

pub const Error = swd.Error || error{ NotHalted, FlashBusy, FlashError, Verify, TooLarge, BadIdentity };

// DEVICE-FIX(uno-q): any other debug port id means the GPIO lines reach a different chip, and flashing it would brick it
pub const expected_dpidr: u32 = 0x0be1_2477;

fn sleepMs(ms: u64) void {
    const ts: std.os.linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.os.linux.nanosleep(&ts, null);
}

fn waitIdle(mem: anytype) Error!void {
    var i: u32 = 0;
    while (i < 20000) : (i += 1) {
        const sr = try mem.read32(nssr);
        if (sr & (sr_bsy | sr_wdw) == 0) {
            if (sr & sr_errors != 0) {
                try mem.write32(nssr, sr_clear);
                return error.FlashError;
            }
            return;
        }
    }
    return error.FlashBusy;
}

pub fn halt(link: anytype) Error!swd.Mem(@TypeOf(link.*)) {
    try link.holdReset(true);
    sleepMs(20);
    const id = link.connect() catch blk: {
        try link.holdReset(false);
        sleepMs(20);
        break :blk try link.connect();
    };
    if (id != expected_dpidr) return error.BadIdentity;
    var mem = try swd.Mem(@TypeOf(link.*)).init(link);
    errdefer restart(link, &mem);
    try mem.write32(dhcsr, dbg_key | 0b11);
    try mem.write32(demcr, (try mem.read32(demcr)) | 1);
    try link.holdReset(false);
    sleepMs(20);
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        if (try mem.read32(dhcsr) & s_halt != 0) return mem;
        try mem.write32(dhcsr, dbg_key | 0b11);
    }
    try mem.write32(aircr, 0x05fa_0004);
    sleepMs(20);
    if (try mem.read32(dhcsr) & s_halt == 0) return error.NotHalted;
    return mem;
}

pub fn program(mem: anytype, image: []const u8) Error!void {
    if (image.len == 0 or image.len > pages_per_bank * page_size) return error.TooLarge;
    try waitIdle(mem);
    try mem.write32(nskeyr, 0x4567_0123);
    try mem.write32(nskeyr, 0xcdef_89ab);
    try mem.write32(nssr, sr_clear);
    defer mem.write32(nscr, cr_lock) catch {};

    const pages = (image.len + page_size - 1) / page_size;
    var page: u32 = 0;
    while (page < pages) : (page += 1) {
        try mem.write32(nscr, cr_per | (page << 3));
        try mem.write32(nscr, cr_per | (page << 3) | cr_strt);
        try waitIdle(mem);
    }
    try mem.write32(nscr, 0);

    try mem.write32(nscr, cr_pg);
    var off: usize = 0;
    while (off < image.len) : (off += 16) {
        var quad = [_]u8{0xff} ** 16;
        const n = @min(16, image.len - off);
        @memcpy(quad[0..n], image[off..][0..n]);
        var w: usize = 0;
        while (w < 4) : (w += 1) {
            try mem.write32(flash_base + @as(u32, @intCast(off + w * 4)), std.mem.readInt(u32, quad[w * 4 ..][0..4], .little));
        }
        try waitIdle(mem);
    }
    try mem.write32(nscr, 0);

    off = 0;
    while (off < image.len) : (off += 4) {
        var word = [_]u8{0xff} ** 4;
        const n = @min(4, image.len - off);
        @memcpy(word[0..n], image[off..][0..n]);
        if (try mem.read32(flash_base + @as(u32, @intCast(off))) != std.mem.readInt(u32, &word, .little)) return error.Verify;
    }
}

pub fn run(link: anytype, mem: anytype) Error!void {
    try mem.write32(demcr, (try mem.read32(demcr)) & ~@as(u32, 1));
    try mem.write32(dhcsr, dbg_key);
    try link.holdReset(true);
    sleepMs(20);
    try link.holdReset(false);
}

pub fn flash(link: anytype, image: []const u8) Error!void {
    var mem = try halt(link);
    errdefer restart(link, &mem);
    try program(&mem, image);
    try run(link, &mem);
}

// restart undoes halt after a failed flash: the halt sets debug registers that
// only a power cycle clears, so without it the controller stays stopped.
pub fn restart(link: anytype, mem: anytype) void {
    mem.write32(nscr, cr_lock) catch {};
    run(link, mem) catch {
        link.holdReset(true) catch {};
        sleepMs(20);
        link.holdReset(false) catch {};
    };
}
