const std = @import("std");
const proto = @import("proto");

pub const firmware_version: u16 = 1;

const width = 13;
const height = 8;
const pixels = width * height;
const levels = 8;
const clock_hz = 24_000_000;
const refresh_hz = 100;
const tick_hz = refresh_hz * pixels * (levels - 1);

// DEVICE-FIX(uno-q): the matrix LEDs sit on PF0..PF10 pin pairs, other pairs light the wrong pixel
const pairs = [pixels]u16{
    0x0001, 0x0100, 0x0002, 0x0200, 0x0102, 0x0201, 0x0003, 0x0300, 0x0103, 0x0301,
    0x0203, 0x0302, 0x0004, 0x0400, 0x0104, 0x0401, 0x0204, 0x0402, 0x0304, 0x0403,
    0x0005, 0x0500, 0x0105, 0x0501, 0x0205, 0x0502, 0x0305, 0x0503, 0x0405, 0x0504,
    0x0006, 0x0600, 0x0106, 0x0601, 0x0206, 0x0602, 0x0306, 0x0603, 0x0406, 0x0604,
    0x0506, 0x0605, 0x0007, 0x0700, 0x0107, 0x0701, 0x0207, 0x0702, 0x0307, 0x0703,
    0x0407, 0x0704, 0x0507, 0x0705, 0x0607, 0x0706, 0x0008, 0x0800, 0x0108, 0x0801,
    0x0208, 0x0802, 0x0308, 0x0803, 0x0408, 0x0804, 0x0508, 0x0805, 0x0608, 0x0806,
    0x0708, 0x0807, 0x0009, 0x0900, 0x0109, 0x0901, 0x0209, 0x0902, 0x0309, 0x0903,
    0x0409, 0x0904, 0x0509, 0x0905, 0x0609, 0x0906, 0x0709, 0x0907, 0x0809, 0x0908,
    0x000a, 0x0a00, 0x010a, 0x0a01, 0x020a, 0x0a02, 0x030a, 0x0a03, 0x040a, 0x0a04,
    0x050a, 0x0a05, 0x060a, 0x0a06,
};

fn reg(addr: u32) *volatile u32 {
    return @ptrFromInt(addr);
}

const rcc = 0x4602_0c00;
const rcc_cr = rcc + 0x000;
const rcc_icscr1 = rcc + 0x008;
const rcc_ahb2enr1 = rcc + 0x08c;
const rcc_ahb3enr = rcc + 0x094;
const rcc_apb3enr = rcc + 0x0a8;
const pwr_svmcr = 0x4602_0800 + 0x010;
const flash_acr = 0x4002_2000;
const gpiof = 0x4202_1400;
const gpiog = 0x4202_1800;
const lpuart = 0x4600_2400;
const syst_csr = 0xe000_e010;
const syst_rvr = 0xe000_e014;
const syst_cvr = 0xe000_e018;

const moder: u32 = 0x00;
const ospeedr: u32 = 0x08;
const bsrr: u32 = 0x18;
const afrl: u32 = 0x20;
const afrh: u32 = 0x24;

const uart_cr1 = lpuart + 0x00;
const uart_cr3 = lpuart + 0x08;
const uart_brr = lpuart + 0x0c;
const uart_isr = lpuart + 0x1c;
const uart_icr = lpuart + 0x20;
const uart_rdr = lpuart + 0x24;
const uart_tdr = lpuart + 0x28;

var frame: [pixels]u8 = [_]u8{0} ** pixels;
var limit: u8 = levels - 1;
var slot: u16 = 0;
var phase: u8 = 0;

const matrix_mask: u32 = (1 << 22) - 1;

fn setMode(port: u32, pin: u5, mode: u2) void {
    const r = reg(port + moder);
    const shift: u5 = pin * 2;
    r.* = (r.* & ~(@as(u32, 3) << shift)) | (@as(u32, mode) << shift);
}

fn setAlt(port: u32, pin: u5, af: u4) void {
    const r = reg(port + if (pin < 8) afrl else afrh);
    const shift: u5 = @as(u5, pin % 8) * 4;
    r.* = (r.* & ~(@as(u32, 0xf) << shift)) | (@as(u32, af) << shift);
    setMode(port, pin, 2);
}

// DEVICE-FIX(uno-q): PG5..PG8 stay dead until VDDIO2 is validated, so the link to Linux never comes up
fn clocks() void {
    reg(flash_acr).* = (reg(flash_acr).* & ~@as(u32, 0xf)) | 2;
    while (reg(flash_acr).* & 0xf != 2) {}
    reg(rcc_icscr1).* = (reg(rcc_icscr1).* & ~(@as(u32, 0xf) << 28)) | (@as(u32, 1) << 28) | (1 << 23);
    while (reg(rcc_cr).* & (1 << 2) == 0) {}
    reg(rcc_ahb3enr).* |= 1 << 2;
    reg(pwr_svmcr).* |= 1 << 29;
    reg(rcc_ahb2enr1).* |= (1 << 5) | (1 << 6);
    reg(rcc_apb3enr).* |= 1 << 6;
    _ = reg(rcc_apb3enr).*;
}

fn matrixInit() void {
    reg(gpiof + moder).* &= ~matrix_mask;
    reg(gpiof + ospeedr).* |= matrix_mask;
}

fn uartInit() void {
    setAlt(gpiog, 7, 8);
    setAlt(gpiog, 8, 8);
    setAlt(gpiog, 6, 8);
    reg(uart_cr1).* = 0;
    reg(uart_brr).* = @intCast((@as(u64, clock_hz) * 256) / 115200);
    reg(uart_cr3).* = 1 << 8;
    reg(uart_cr1).* = (1 << 29) | (1 << 3) | (1 << 2) | 1;
}

fn tickInit() void {
    reg(syst_rvr).* = clock_hz / tick_hz - 1;
    reg(syst_cvr).* = 0;
    reg(syst_csr).* = 7;
}

fn send(kind: proto.Kind, payload: []const u8) void {
    var out: [proto.max_packet]u8 = undefined;
    for (proto.encode(&out, kind, payload)) |b| {
        while (reg(uart_isr).* & (1 << 7) == 0) {}
        reg(uart_tdr).* = b;
    }
}

fn handle(p: proto.Packet) void {
    switch (p.kind) {
        .hello => {
            const info: proto.Info = .{ .proto = proto.version, .width = width, .height = height, .levels = levels, .firmware = firmware_version };
            send(.info, std.mem.asBytes(&info));
        },
        .frame => if (p.payload.len == pixels) {
            for (p.payload, 0..) |v, i| frame[i] = @min(v, levels - 1);
        },
        .brightness => if (p.payload.len == 1) {
            limit = @min(p.payload[0], levels - 1);
        },
        .clear => @memset(&frame, 0),
        else => {},
    }
}

export fn sysTick() callconv(.c) void {
    const port = reg(gpiof + moder);
    port.* &= ~matrix_mask;
    const level = @min(frame[slot], limit);
    if (level > phase) {
        const pair = pairs[slot];
        const high: u5 = @intCast(pair >> 8);
        const low: u5 = @intCast(pair & 0xff);
        reg(gpiof + bsrr).* = (@as(u32, 1) << high) | (@as(u32, 1) << (@as(u5, low) + 16));
        port.* |= (@as(u32, 1) << (high * 2)) | (@as(u32, 1) << (low * 2));
    }
    slot += 1;
    if (slot == pixels) {
        slot = 0;
        phase = (phase + 1) % (levels - 1);
    }
}

export fn reset() callconv(.c) noreturn {
    const data_start = @extern([*]u8, .{ .name = "__data_start" });
    const data_end = @extern([*]u8, .{ .name = "__data_end" });
    const data_load = @extern([*]const u8, .{ .name = "__data_load" });
    const bss_start = @extern([*]u8, .{ .name = "__bss_start" });
    const bss_end = @extern([*]u8, .{ .name = "__bss_end" });
    const data_len = @intFromPtr(data_end) - @intFromPtr(data_start);
    @memcpy(data_start[0..data_len], data_load[0..data_len]);
    @memset(bss_start[0 .. @intFromPtr(bss_end) - @intFromPtr(bss_start)], 0);

    clocks();
    matrixInit();
    uartInit();
    tickInit();
    var parser: proto.Parser = .{};
    while (true) {
        const isr = reg(uart_isr).*;
        if (isr & (1 << 3) != 0) reg(uart_icr).* = 1 << 3;
        if (isr & (1 << 5) != 0) {
            const b: u8 = @truncate(reg(uart_rdr).*);
            if (parser.push(b)) |p| handle(p);
        }
    }
}

export fn fault() callconv(.c) noreturn {
    while (true) {}
}

export const vectors linksection(".vectors") = [16]?*const anyopaque{
    @extern(*const anyopaque, .{ .name = "__stack_top" }),
    @ptrCast(&reset),
    @ptrCast(&fault),
    @ptrCast(&fault),
    @ptrCast(&fault),
    @ptrCast(&fault),
    @ptrCast(&fault),
    null,
    null,
    null,
    null,
    @ptrCast(&fault),
    @ptrCast(&fault),
    null,
    @ptrCast(&fault),
    @ptrCast(&sysTick),
};
