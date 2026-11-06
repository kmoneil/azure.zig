//! CRC-64/NVME: the checksum Blob Storage takes beside a block's or a
//! blob's bytes, and sends back, in `x-ms-content-crc64`: the reflected
//! polynomial 0x9A6C9329AC4BC9B5, all ones in and out, sent as the value's
//! eight little-endian bytes in standard base64. Zig 0.17.1's
//! `std.hash.crc` has six CRC-64s but not this one.
//!
//! Where the build's CPU multiplies without carries (x86_64's PCLMULQDQ
//! with AVX, aarch64's PMULL), four lanes of 16 bytes fold at once; the
//! fold constants are powers of x modulo the polynomial, worked out at
//! compile time. Everywhere else eight tables do, eight bytes at a time.
//! The build chooses at compile time, as gcp.zig's crc32c does: a baseline
//! build cannot carry the instructions.

const std = @import("std");
const builtin = @import("builtin");

/// The polynomial, reflected, as the CRC catalogues name it.
pub const polynomial: u64 = 0x9A6C9329AC4BC9B5;

/// How this build computes a CRC-64.
pub const Implementation = enum {
    /// Carry-less multiplies, four lanes at once.
    clmul,
    /// Eight tables, eight bytes at a time, on any target.
    software,
};

const has_clmul = builtin.zig_backend != .stage2_c and switch (builtin.cpu.arch) {
    .x86_64 => builtin.cpu.has(.x86, .pclmul) and builtin.cpu.has(.x86, .avx),
    .aarch64 => builtin.cpu.has(.aarch64, .aes),
    else => false,
};

/// Decided by the build's target CPU.
pub const implementation: Implementation = if (has_clmul) .clmul else .software;

/// A CRC-64/NVME over bytes that arrive in pieces.
pub const Hasher = struct {
    /// The register, before the final inversion.
    state: u64 = ~@as(u64, 0),

    pub fn init() Hasher {
        return .{};
    }

    pub fn update(self: *Hasher, bytes: []const u8) void {
        self.state = if (has_clmul) folded(self.state, bytes) else tables(self.state, bytes);
    }

    pub fn final(self: Hasher) u64 {
        return ~self.state;
    }
};

pub fn hash(data: []const u8) u64 {
    var h: Hasher = .init();
    h.update(data);
    return h.final();
}

/// The tables alone, whatever the CPU: what the fast path is held to.
pub fn hashSoftware(data: []const u8) u64 {
    return ~tables(~@as(u64, 0), data);
}

/// The CRC as `x-ms-content-crc64` carries it.
pub fn toBase64(value: u64) [12]u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    var out: [12]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &bytes);
    return out;
}

/// The CRC an `x-ms-content-crc64` header names. A server sent it, so its
/// decoded size is checked before anything is decoded: twelve characters
/// with no padding are nine bytes, which std's decoder would write past an
/// eight-byte buffer.
pub fn fromBase64(text: []const u8) error{InvalidCrc64}!u64 {
    if (text.len != 12) return error.InvalidCrc64;
    const size = std.base64.standard.Decoder.calcSizeForSlice(text) catch return error.InvalidCrc64;
    if (size != 8) return error.InvalidCrc64;
    var bytes: [8]u8 = undefined;
    std.base64.standard.Decoder.decode(&bytes, text) catch return error.InvalidCrc64;
    // A canonical encoding only: the padding bits must be zero.
    if (!std.mem.eql(u8, &toBase64(std.mem.readInt(u64, &bytes, .little)), text)) return error.InvalidCrc64;
    return std.mem.readInt(u64, &bytes, .little);
}

/// The CRC of `a ++ b` from the CRCs of `a` and `b` and the length of `b`,
/// for parts hashed apart, as parallel uploads hash them. With all ones in
/// and out, it is `crc_a` advanced over `len_b` zero bytes, xor `crc_b`.
pub fn combine(crc_a: u64, crc_b: u64, len_b: u64) u64 {
    return advance(crc_a, len_b) ^ crc_b;
}

// The tables.

const table: [8][256]u64 = t: {
    @setEvalBranchQuota(100_000);
    var t: [8][256]u64 = undefined;
    for (0..256) |b| {
        var crc: u64 = b;
        for (0..8) |_| crc = if (crc & 1 != 0) (crc >> 1) ^ polynomial else crc >> 1;
        t[0][b] = crc;
    }
    for (1..8) |k| {
        for (0..256) |b| t[k][b] = (t[k - 1][b] >> 8) ^ t[0][@as(u8, @truncate(t[k - 1][b]))];
    }
    break :t t;
};

fn tables(register: u64, data: []const u8) u64 {
    var crc = register;
    var i: usize = 0;
    while (i + 8 <= data.len) : (i += 8) {
        const v = crc ^ std.mem.readInt(u64, data[i..][0..8], .little);
        crc = table[7][@as(u8, @truncate(v))] ^ table[6][@as(u8, @truncate(v >> 8))] ^
            table[5][@as(u8, @truncate(v >> 16))] ^ table[4][@as(u8, @truncate(v >> 24))] ^
            table[3][@as(u8, @truncate(v >> 32))] ^ table[2][@as(u8, @truncate(v >> 40))] ^
            table[1][@as(u8, @truncate(v >> 48))] ^ table[0][@as(u8, @truncate(v >> 56))];
    }
    for (data[i..]) |byte| crc = table[0][@as(u8, @truncate(crc)) ^ byte] ^ (crc >> 8);
    return crc;
}

// The fold.
//
// A 128-bit accumulator holds 16 bytes of message still to be reduced: bit
// j, the (j % 8)th bit of byte j / 8, stands for x^(127 - j). Folding it
// over the next s bits of message multiplies it by x^s, and modulo P that
// is its first 64 bits times x^(s + 64) plus its last 64 times x^s. A
// carry-less multiply of two reflected 64-bit values gives the reflected
// product times x, so each constant is the power one lower, reflected:
// x^(s + 63) mod P for the low half and x^(s - 1) mod P for the high.

const lanes = 4;

/// Below this the tables are as fast, and the fold needs its lanes full.
const fold_min = 2 * lanes * 16;

const Fold = struct { lo: u64, hi: u64 };

fn foldBy(comptime bits: u64) Fold {
    return .{ .lo = @bitReverse(xPowModP(bits + 63)), .hi = @bitReverse(xPowModP(bits - 1)) };
}

const across = foldBy(128 * lanes);
const one_block = foldBy(128);

fn folded(register: u64, data: []const u8) u64 {
    if (data.len < fold_min) return tables(register, data);
    var acc: [lanes]u128 = undefined;
    inline for (0..lanes) |l| acc[l] = load(data, l * 16);
    // The register, xored into the first eight bytes, is the CRC's start.
    acc[0] ^= register;
    var i: usize = lanes * 16;
    while (i + lanes * 16 <= data.len) : (i += lanes * 16) {
        inline for (0..lanes) |l| acc[l] = fold(acc[l], across) ^ load(data, i + l * 16);
    }
    var a = acc[lanes - 1];
    inline for (0..lanes - 1) |l| a ^= fold(acc[l], comptime foldBy(128 * (lanes - 1 - l)));
    while (i + 16 <= data.len) : (i += 16) a = fold(a, one_block) ^ load(data, i);
    var last: [16]u8 = undefined;
    std.mem.writeInt(u128, &last, a, .little);
    return tables(tables(0, &last), data[i..]);
}

inline fn load(data: []const u8, at: usize) u128 {
    return std.mem.readInt(u128, data[at..][0..16], .little);
}

inline fn fold(a: u128, k: Fold) u128 {
    return clmul(@truncate(a), k.lo) ^ clmul(@truncate(a >> 64), k.hi);
}

inline fn clmul(a: u64, b: u64) u128 {
    if (!has_clmul) return clmulSoft(a, b);
    const x: @Vector(2, u64) = .{ a, 0 };
    const y: @Vector(2, u64) = .{ b, 0 };
    const product = switch (builtin.cpu.arch) {
        .x86_64 => asm (
            \\ vpclmulqdq $0x00, %[x], %[y], %[out]
            : [out] "=x" (-> @Vector(2, u64)),
            : [x] "x" (x),
              [y] "x" (y),
        ),
        .aarch64 => asm (
            \\ pmull %[out].1q, %[x].1d, %[y].1d
            : [out] "=w" (-> @Vector(2, u64)),
            : [x] "w" (x),
              [y] "w" (y),
        ),
        else => unreachable,
    };
    return @bitCast(product);
}

/// A carry-less multiply in software: what the instructions compute, for
/// tests on any CPU.
fn clmulSoft(a: u64, b: u64) u128 {
    var product: u128 = 0;
    var x: u128 = a;
    var y = b;
    while (y != 0) : (y >>= 1) {
        if (y & 1 != 0) product ^= x;
        x <<= 1;
    }
    return product;
}

// Arithmetic modulo P, in the unreflected form: bit i stands for x^i.

const normal: u64 = @bitReverse(polynomial);

fn timesX(r: u64) u64 {
    return (r << 1) ^ (if (r >> 63 != 0) normal else 0);
}

/// x^n mod P.
fn xPowModP(n: u64) u64 {
    @setEvalBranchQuota(1_000_000);
    var r: u64 = 1;
    for (0..n) |_| r = timesX(r);
    return r;
}

fn mulModP(a: u64, b: u64) u64 {
    var product: u64 = 0;
    var x = a;
    var y = b;
    while (y != 0) : (y >>= 1) {
        if (y & 1 != 0) product ^= x;
        x = timesX(x);
    }
    return product;
}

/// A register advanced over `len` zero bytes: times x^(8 len) mod P.
fn advance(register: u64, len: u64) u64 {
    var power: u64 = 1;
    var base: u64 = 1 << 8; // x^8
    var n = len;
    while (n != 0) : (n >>= 1) {
        if (n & 1 != 0) power = mulModP(power, base);
        base = mulModP(base, base);
    }
    return @bitReverse(mulModP(@bitReverse(register), power));
}

const testing = std.testing;

test "the vectors research-blob gathered, and the catalogue's check value" {
    for ([_]struct { []const u8, []const u8 }{
        .{ "", "AAAAAAAAAAA=" },
        .{ "Hello Azure!", "DtjZpL9/o8c=" },
        .{ "Hello World!", "peH8Xsgc5QI=" },
        .{ "123456789", "iJh5CoYUi64=" },
    }) |v| {
        try testing.expectEqualStrings(v[1], &toBase64(hash(v[0])));
        try testing.expectEqualStrings(v[1], &toBase64(hashSoftware(v[0])));
        try testing.expectEqual(hash(v[0]), try fromBase64(v[1]));
    }
    try testing.expectEqual(0xAE8B14860A799888, hash("123456789"));
}

test "std's own CRC, built from NVME's parameters, agrees" {
    const Std = std.hash.crc.Generic(u64, .{
        .polynomial = normal,
        .initial = ~@as(u64, 0),
        .reflect_input = true,
        .reflect_output = true,
        .xor_output = ~@as(u64, 0),
    });
    var data: [3000]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xc64);
    prng.random().bytes(&data);
    for ([_]usize{ 0, 1, 7, 8, 9, 127, 128, 129, 1000, 3000 }) |n| {
        try testing.expectEqual(Std.hash(data[0..n]), hash(data[0..n]));
    }
}

test "the fold agrees with the tables at every length to 700, and at 4 MiB" {
    var data: [700]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    prng.random().bytes(&data);
    for (0..data.len + 1) |n| {
        try testing.expectEqual(tables(~@as(u64, 0), data[0..n]), folded(~@as(u64, 0), data[0..n]));
        try testing.expectEqual(tables(0x0123456789abcdef, data[0..n]), folded(0x0123456789abcdef, data[0..n]));
    }
    const big = try testing.allocator.alloc(u8, 4 * 1024 * 1024 + 13);
    defer testing.allocator.free(big);
    prng.random().bytes(big);
    try testing.expectEqual(tables(~@as(u64, 0), big), folded(~@as(u64, 0), big));
    try testing.expectEqual(hashSoftware(big), hash(big));
}

test "the CPU's carry-less multiply, where there is one, is the software's" {
    var prng: std.Random.DefaultPrng = .init(7);
    for (0..1000) |_| {
        const a = prng.random().int(u64);
        const b = prng.random().int(u64);
        try testing.expectEqual(clmulSoft(a, b), clmul(a, b));
    }
    try testing.expectEqual(@as(u128, 0b1111), clmulSoft(0b11, 0b101));
}

test "fromBase64 takes only the canonical twelve characters" {
    for ([_][]const u8{ "", "AAAAAAAAAAA", "AAAAAAAAAAA==", "AAAAAAAAAAB=", "AAAAAAAAAA!=", "AAAAAAAAAAAA" }) |text| {
        try testing.expectError(error.InvalidCrc64, fromBase64(text));
    }
}

fn property(_: void, input: []const u8) !void {
    const core_testing = @import("testing.zig");
    var g: core_testing.ByteGen = .init(input);
    const register = g.int(u64);
    const data = g.rest();
    const cut = if (data.len == 0) 0 else register % (data.len + 1);
    // The fold is the tables, from any register.
    try testing.expectEqual(tables(register, data), folded(register, data));
    // Pieces fed one after another are the whole.
    var h: Hasher = .init();
    h.update(data[0..cut]);
    h.update(data[cut..]);
    try testing.expectEqual(hashSoftware(data), h.final());
    // Two parts hashed apart combine to the whole's CRC.
    try testing.expectEqual(hashSoftware(data), combine(hash(data[0..cut]), hash(data[cut..]), data.len - cut));
}

test "fuzz crc64: fold, pieces and combine all agree with the tables" {
    const core_testing = @import("testing.zig");
    try core_testing.fuzzBytes({}, property, .{ .corpus = &.{
        "\x00\x00\x00\x00\x00\x00\x00\x00",
        "\xff\xff\xff\xff\xff\xff\xff\xff" ++ "Hello Azure!",
        "\x40\x00\x00\x00\x00\x00\x00\x00" ++ "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef!",
    } });
}
