//! An amount of money exactly as the API wrote it: whole units and
//! billionths, read from the number's digits, never through a float. The
//! Retail Prices API writes prices like `0.015919` (seven decimals at most,
//! measured); one finer than a billionth is refused rather than rounded.

const Amount = @This();

const std = @import("std");

/// Whole units of the currency.
units: u64 = 0,
/// Billionths, 0 to 999,999,999.
nanos: u32 = 0,

pub fn toNanos(a: Amount) u128 {
    return @as(u128, a.units) * 1_000_000_000 + a.nanos;
}

pub fn order(a: Amount, b: Amount) std.math.Order {
    return std.math.order(a.toNanos(), b.toNanos());
}

/// A JSON number's text as an amount: digits, a fraction, an exponent.
/// Null for a negative number, for one past `maxInt(u64)` units, and for one
/// with a non-zero digit finer than a billionth.
pub fn parse(text: []const u8) ?Amount {
    var digits: u128 = 0;
    var count: usize = 0;
    var scale: i64 = 0; // the power of ten `digits` is multiplied by
    var i: usize = 0;
    var seen_point = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '.' and !seen_point) {
            seen_point = true;
            continue;
        }
        if (!std.ascii.isDigit(c)) break;
        if (digits == 0 and c == '0') {
            if (seen_point) scale -= 1;
            continue;
        }
        count += 1;
        if (count > 30) return null;
        digits = digits * 10 + (c - '0');
        if (seen_point) scale -= 1;
    }
    if (i == 0 or (i == 1 and seen_point)) return null;
    if (i < text.len) scale += exponent(text[i..]) orelse return null;
    return fromScaled(digits, scale);
}

/// `e` or `E`, a sign, and digits, as JSON writes an exponent.
fn exponent(text: []const u8) ?i64 {
    if (text.len < 2 or (text[0] != 'e' and text[0] != 'E')) return null;
    var rest = text[1..];
    var negative = false;
    if (rest[0] == '+' or rest[0] == '-') {
        negative = rest[0] == '-';
        rest = rest[1..];
    }
    if (rest.len == 0 or rest.len > 4) return null;
    for (rest) |c| if (!std.ascii.isDigit(c)) return null;
    const value = std.fmt.parseInt(i64, rest, 10) catch return null;
    return if (negative) -value else value;
}

/// `digits` times ten to `scale`, in billionths, when it fits exactly.
fn fromScaled(digits: u128, scale: i64) ?Amount {
    if (digits == 0) return .{};
    const shift = scale + 9;
    var nanos: u128 = digits;
    if (shift >= 0) {
        if (shift > 38) return null;
        const factor = std.math.powi(u128, 10, @intCast(shift)) catch return null;
        nanos = std.math.mul(u128, digits, factor) catch return null;
    } else {
        if (shift < -38) return null;
        const divisor = std.math.powi(u128, 10, @intCast(-shift)) catch return null;
        if (digits % divisor != 0) return null;
        nanos = digits / divisor;
    }
    const units = nanos / 1_000_000_000;
    if (units > std.math.maxInt(u64)) return null;
    return .{ .units = @intCast(units), .nanos = @intCast(nanos % 1_000_000_000) };
}

/// Writes the amount as a decimal, its fraction without trailing zeros:
/// `0.015919`, `465`.
pub fn format(a: Amount, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("{d}", .{a.units});
    if (a.nanos == 0) return;
    // Ten bytes: `nanos` is a u32, though a valid amount's has nine digits.
    var fraction: [10]u8 = undefined;
    const digits = std.fmt.bufPrint(&fraction, "{d:0>9}", .{a.nanos}) catch unreachable;
    try w.print(".{s}", .{std.mem.trimEnd(u8, digits, "0")});
}

/// Read straight from the JSON number's text, so no float ever holds it.
pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Amount {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len orelse std.json.Scanner.default_max_value_len);
    const text = switch (token) {
        .number, .allocated_number => |t| t,
        else => return error.UnexpectedToken,
    };
    return parse(text) orelse error.InvalidNumber;
}

const testing = std.testing;

test "parse: the API's prices, exactly" {
    try testing.expectEqual(Amount{ .nanos = 15_919_000 }, parse("0.015919").?);
    try testing.expectEqual(Amount{ .units = 465 }, parse("465.0").?);
    try testing.expectEqual(Amount{ .units = 893 }, parse("893").?);
    try testing.expectEqual(Amount{ .nanos = 10_275_000 }, parse("0.010275").?);
    try testing.expectEqual(Amount{}, parse("0").?);
    try testing.expectEqual(Amount{}, parse("0.0").?);
    try testing.expectEqual(Amount{ .nanos = 16_000 }, parse("1.6E-05").?);
    try testing.expectEqual(Amount{ .units = 12, .nanos = 500_000_000 }, parse("1.25e1").?);
    try testing.expectEqual(Amount{ .nanos = 1 }, parse("0.000000001").?);
    try testing.expectEqual(Amount{ .nanos = 1 }, parse("1e-9").?);
}

test "parse: refused rather than rounded, or wrong" {
    for ([_][]const u8{ "", ".", "-0.5", "0.0000000001", "1e-10", "abc", "1.2.3", "1e", "1e+", "1x", "1e99999", "18446744073709551616" }) |text| {
        if (parse(text)) |a| {
            std.debug.print("took {s} as {d}.{d}\n", .{ text, a.units, a.nanos });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(Amount{ .units = std.math.maxInt(u64) }, parse("18446744073709551615").?);
}

test "format: a decimal without trailing zeros" {
    var buf: [64]u8 = undefined;
    for ([_]struct { Amount, []const u8 }{
        .{ .{ .nanos = 15_919_000 }, "0.015919" },
        .{ .{ .units = 465 }, "465" },
        .{ .{ .units = 1, .nanos = 1 }, "1.000000001" },
        .{ .{}, "0" },
    }) |case| {
        var w: std.Io.Writer = .fixed(&buf);
        try case[0].format(&w);
        try testing.expectEqualStrings(case[1], w.buffered());
    }
}

test "jsonParse: from the number's text, in a struct" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Row = struct { retailPrice: Amount };
    const row = try std.json.parseFromSliceLeaky(Row, arena.allocator(), "{\"retailPrice\":0.015919}", .{});
    try testing.expectEqual(Amount{ .nanos = 15_919_000 }, row.retailPrice);
    try testing.expectError(error.UnexpectedToken, std.json.parseFromSliceLeaky(Row, arena.allocator(), "{\"retailPrice\":\"0.1\"}", .{}));
    try testing.expectError(error.InvalidNumber, std.json.parseFromSliceLeaky(Row, arena.allocator(), "{\"retailPrice\":1e-12}", .{}));
}

fn roundTrip(_: void, input: []const u8) !void {
    // Whatever parse takes, format writes back a number parse reads the same.
    const a = parse(input) orelse return;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try a.format(&w);
    try testing.expectEqual(a, parse(w.buffered()).?);
}

test "fuzz parse and format: what is taken writes back as itself" {
    try @import("core").testing.fuzzBytes({}, roundTrip, .{ .corpus = &.{ "0.015919", "465.0", "1.6E-05", "1e-9", "18446744073709551615", "0.0" } });
}
