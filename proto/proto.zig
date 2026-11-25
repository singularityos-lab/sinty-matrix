const std = @import("std");

pub const version: u8 = 1;
pub const magic = [2]u8{ 0xa5, 0x5a };
pub const max_payload = 255;
pub const header_len = 4;
pub const max_packet = header_len + max_payload + 1;

pub const Kind = enum(u8) {
    hello = 0x01,
    frame = 0x10,
    brightness = 0x11,
    clear = 0x12,
    hold = 0x13,
    info = 0x81,
    _,
};

pub const Info = extern struct {
    proto: u8,
    width: u8,
    height: u8,
    levels: u8,
    firmware: u16 align(1),
};

pub fn crc8(bytes: []const u8) u8 {
    var crc: u8 = 0;
    for (bytes) |b| {
        crc ^= b;
        var i: u4 = 0;
        while (i < 8) : (i += 1) crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
    }
    return crc;
}

pub fn encode(out: []u8, kind: Kind, payload: []const u8) []u8 {
    std.debug.assert(payload.len <= max_payload and out.len >= header_len + payload.len + 1);
    out[0] = magic[0];
    out[1] = magic[1];
    out[2] = @intFromEnum(kind);
    out[3] = @intCast(payload.len);
    @memcpy(out[header_len..][0..payload.len], payload);
    const end = header_len + payload.len;
    out[end] = crc8(out[2..end]);
    return out[0 .. end + 1];
}

pub const Packet = struct {
    kind: Kind,
    payload: []const u8,
};

pub const Parser = struct {
    buf: [max_packet]u8 = undefined,
    len: usize = 0,

    pub fn push(self: *Parser, byte: u8) ?Packet {
        if (self.len < 2 and byte != magic[self.len]) {
            self.len = if (byte == magic[0]) 1 else 0;
            return null;
        }
        self.buf[self.len] = byte;
        self.len += 1;
        if (self.len < header_len) return null;
        const need = header_len + @as(usize, self.buf[3]) + 1;
        if (self.len < need) return null;
        self.len = 0;
        if (crc8(self.buf[2 .. need - 1]) != self.buf[need - 1]) return null;
        return .{ .kind = @enumFromInt(self.buf[2]), .payload = self.buf[header_len .. need - 1] };
    }
};

test "packets survive a round trip through the parser" {
    var out: [max_packet]u8 = undefined;
    const levels = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 } ** 13;
    const pkt = encode(&out, .frame, &levels);
    var p: Parser = .{};
    var got: ?Packet = null;
    for ([_]u8{ 0x00, 0xa5, 0x13 }) |b| try std.testing.expect(p.push(b) == null);
    for (pkt) |b| got = p.push(b);
    try std.testing.expect(got != null);
    try std.testing.expectEqual(Kind.frame, got.?.kind);
    try std.testing.expectEqualSlices(u8, &levels, got.?.payload);
}

test "a corrupted packet is dropped and the next one is read" {
    var out: [max_packet]u8 = undefined;
    var bad: [max_packet]u8 = undefined;
    const first = encode(&bad, .brightness, &.{5});
    first[4] ^= 1;
    var p: Parser = .{};
    for (first) |b| try std.testing.expect(p.push(b) == null);
    var got: ?Packet = null;
    for (encode(&out, .hello, &.{})) |b| got = p.push(b);
    try std.testing.expectEqual(Kind.hello, got.?.kind);
    try std.testing.expectEqual(@as(usize, 0), got.?.payload.len);
}

test "the info record keeps its wire layout" {
    try std.testing.expectEqual(@as(usize, 6), @sizeOf(Info));
}

test "any byte stream is survived and a clean packet after a pause is always read" {
    var prng = std.Random.DefaultPrng.init(0xa55a);
    const rand = prng.random();
    var p: Parser = .{};
    var out: [max_packet]u8 = undefined;
    var payload: [max_payload]u8 = undefined;
    for (0..5000) |_| {
        for (0..rand.uintAtMost(usize, 600)) |_| {
            if (p.push(rand.int(u8))) |got| try std.testing.expect(got.payload.len <= max_payload);
        }
        for (0..max_packet) |_| _ = p.push(0);
        const len = rand.uintAtMost(usize, max_payload);
        rand.bytes(payload[0..len]);
        const kind: Kind = @enumFromInt(rand.int(u8));
        var got: ?Packet = null;
        for (encode(&out, kind, payload[0..len])) |b| {
            try std.testing.expect(got == null);
            got = p.push(b);
        }
        try std.testing.expect(got != null);
        try std.testing.expectEqual(kind, got.?.kind);
        try std.testing.expectEqualSlices(u8, payload[0..len], got.?.payload);
    }
}
