// After gcp.zig src/auth/Cache.zig at 323aa61: its one-fetch-at-a-time, keep-a-valid-token rules and its wiping. Azure's own here: a token per scope, and azcore's refresh times.
//! Access tokens, one per scope, each refreshed before it expires. Every
//! credential in this module embeds a `Cache` and hands it a `Source` that
//! fetches a token for a scope. One credential can serve several clients
//! at once, Resource Manager's and Storage's, each asking its own scope.
//!
//! By a token's remaining life when `getToken` is called:
//!
//! - fresh: the cached token, with no I/O;
//! - stale, five minutes or less from expiry, or past the `refresh_in`
//!   Entra asked: a fetch. If it fails, the cached token, which is still
//!   valid, a warning in the log, and another try 30 s later;
//! - expired, missing or invalidated: a fetch. If it fails, the error.
//!
//! A token that lives less than ten minutes is refreshed at half its life.
//! The cache counts from the moment a token arrived and its `expires_in`,
//! never from the token's own `iat`, which Entra sets five minutes back.

const Cache = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;

const log = core.logging.Scoped(.azure_auth);

gpa: Allocator,
options: Options,
mutex: std.Io.Mutex = .init,
/// Set by `invalidate`, which cannot wait for the mutex. The next
/// `getToken` drops every token.
invalidated: std.atomic.Value(bool) = .init(false),
entries: std.ArrayList(Entry) = .empty,

/// One scope's token. Owned by the cache, and wiped before it is freed.
const Entry = struct {
    scope: []u8,
    /// Empty when there is none.
    token: []u8 = &.{},
    /// Both on the boot clock, which keeps counting while the machine sleeps.
    refresh_at: std.Io.Timestamp = .zero,
    expires_at: std.Io.Timestamp = .zero,
};

pub const Options = struct {
    /// Fetch a new token when this little of its life remains: azcore's
    /// five minutes.
    refresh_margin_s: u32 = 300,
    /// After an early refresh fails, how long to keep the valid token
    /// before trying again: azcore's 30 s.
    retry_delay_s: u32 = 30,
    /// A token that claims to live longer is treated as living this long.
    max_lifetime_s: u32 = 24 * 60 * 60,
    /// Scopes held at most. A credential asked for more drops the oldest.
    max_scopes: u32 = 16,
};

/// A token from a `Source`.
pub const Fetched = struct {
    /// May point into the arena passed to the fetch. The cache copies it,
    /// then wipes and frees the arena.
    token: []const u8,
    /// Seconds until the token expires, as the server said.
    expires_in: i64,
    /// Seconds until the server would have it refreshed, when it said.
    refresh_in: ?i64 = null,
};

/// How a credential fetches a token for one scope.
pub const Source = struct {
    ptr: *anyopaque,
    fetchFn: *const fn (ptr: *anyopaque, io: std.Io, arena: Allocator, scope: []const u8) TokenProvider.Error!Fetched,

    pub fn fetch(source: Source, io: std.Io, arena: Allocator, scope: []const u8) TokenProvider.Error!Fetched {
        return source.fetchFn(source.ptr, io, arena, scope);
    }
};

pub const InitError = error{
    /// A margin, delay or lifetime that is 0, or a margin as long as the
    /// longest life.
    InvalidOptions,
};

pub fn init(gpa: Allocator, options: Options) InitError!Cache {
    if (options.refresh_margin_s == 0 or options.retry_delay_s == 0 or options.max_lifetime_s <= options.refresh_margin_s or options.max_scopes == 0) {
        return error.InvalidOptions;
    }
    return .{ .gpa = gpa, .options = options };
}

/// Wipes and frees every token. Nothing may be using the cache.
pub fn deinit(self: *Cache) void {
    for (self.entries.items) |*e| self.dropEntry(e);
    // Reserved once, never grown, so this is the only block it had.
    const block = std.mem.sliceAsBytes(self.entries.allocatedSlice());
    if (block.len > 0) {
        std.crypto.secureZero(u8, block);
        self.gpa.rawFree(block, .of(Entry), @returnAddress());
    }
    self.* = undefined;
}

/// A token for `scope` valid for at least the next request, copied into
/// `arena`. Callers that arrive during a fetch wait for it.
pub fn getToken(self: *Cache, io: std.Io, arena: Allocator, scope: []const u8, source: Source) TokenProvider.Error![]const u8 {
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);
    if (self.invalidated.swap(false, .acq_rel)) self.dropAll();
    const e = try self.entry(scope);
    const now = std.Io.Timestamp.now(io, .boot);
    if (e.token.len != 0 and now.nanoseconds < e.refresh_at.nanoseconds) return arena.dupe(u8, e.token);
    self.refresh(io, e, source, now) catch |err| {
        // A stale token is still valid, and a failed early refresh is no
        // reason to fail the call. Cancellation and lack of memory are.
        const valid = e.token.len != 0 and now.nanoseconds < e.expires_at.nanoseconds;
        if (!valid or err == error.Canceled or err == error.OutOfMemory) return err;
        const retry_at = now.addDuration(.fromSeconds(self.options.retry_delay_s));
        e.refresh_at = if (retry_at.nanoseconds < e.expires_at.nanoseconds) retry_at else e.expires_at;
        log.warn("refreshing a token failed with {t}; the cached one is good for {d} s more", .{
            err, now.durationTo(e.expires_at).toSeconds(),
        });
    };
    return arena.dupe(u8, e.token);
}

/// Drops every token, so each next `getToken` fetches a new one. If that
/// fetch fails, the call fails: a token the server refused is not reused.
/// Does not block.
pub fn invalidate(self: *Cache) void {
    self.invalidated.store(true, .release);
}

/// The entry for `scope`, made when there is none; past `max_scopes`, the
/// oldest goes.
fn entry(self: *Cache, scope: []const u8) Allocator.Error!*Entry {
    for (self.entries.items) |*e| if (std.mem.eql(u8, e.scope, scope)) return e;
    // Room for every scope at once, so the list never moves: a pointer to
    // an entry stays good, and no block is freed unwiped.
    if (self.entries.capacity == 0) try self.entries.ensureTotalCapacityPrecise(self.gpa, self.options.max_scopes);
    if (self.entries.items.len == self.options.max_scopes) {
        self.dropEntry(&self.entries.items[0]);
        _ = self.entries.orderedRemove(0);
    }
    const copy = try self.gpa.dupe(u8, scope);
    self.entries.appendAssumeCapacity(.{ .scope = copy });
    return &self.entries.items[self.entries.items.len - 1];
}

fn refresh(self: *Cache, io: std.Io, e: *Entry, source: Source, now: std.Io.Timestamp) TokenProvider.Error!void {
    // Whatever the source kept in its scratch memory held the token, and a
    // secret, too.
    var wiping: core.WipingAllocator = .init(self.gpa);
    var scratch: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer scratch.deinit();
    const fetched = try source.fetch(io, scratch.allocator(), e.scope);
    if (!TokenProvider.isValidToken(fetched.token) or fetched.expires_in <= 0) return error.InvalidTokenResponse;
    const lifetime_s: u32 = @intCast(@min(fetched.expires_in, self.options.max_lifetime_s));
    const copy = try self.gpa.dupe(u8, fetched.token);
    self.dropToken(e);
    e.token = copy;
    e.expires_at = now.addDuration(.fromSeconds(lifetime_s));
    e.refresh_at = now.addDuration(.fromSeconds(self.refreshAfter(lifetime_s, fetched.refresh_in)));
    log.debug("fetched a token of {d} bytes, good for {d} s", .{ copy.len, lifetime_s });
}

/// Seconds from now until a token that lives `lifetime_s` is refreshed:
/// the margin before its end, or half its life when that is shorter, and
/// sooner when the server asked.
fn refreshAfter(self: *const Cache, lifetime_s: u32, refresh_in: ?i64) u32 {
    var after = if (lifetime_s > 2 * self.options.refresh_margin_s) lifetime_s - self.options.refresh_margin_s else lifetime_s / 2;
    if (refresh_in) |r| if (r > 0 and r < after) {
        after = @intCast(r);
    };
    return after;
}

fn dropAll(self: *Cache) void {
    for (self.entries.items) |*e| self.dropToken(e);
}

fn dropEntry(self: *Cache, e: *Entry) void {
    self.dropToken(e);
    wipeFree(self.gpa, e.scope);
}

/// Wipes the token and frees it with `rawFree`, so the wipe is the last
/// write: `Allocator.free` would overwrite it with a debug pattern first.
fn dropToken(self: *Cache, e: *Entry) void {
    if (e.token.len == 0) return;
    wipeFree(self.gpa, e.token);
    e.token = &.{};
}

fn wipeFree(gpa: Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    gpa.rawFree(bytes, .fromByteUnits(@alignOf(u8)), @returnAddress());
}

const testing = std.testing;
const FakeClock = core.testing.FakeClock;
const WipeChecker = core.testing.WipeChecker;

/// A `Source` that answers each fetch with the next scripted reply, and
/// remembers the scopes it was asked.
const FakeSource = struct {
    replies: []const Reply,
    next: usize = 0,
    fetches: usize = 0,
    last_scope: [64]u8 = undefined,
    last_scope_len: usize = 0,

    const Reply = union(enum) {
        token: struct { []const u8, i64, ?i64 },
        fail: TokenProvider.Error,
    };

    fn source(self: *FakeSource) Source {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn lastScope(self: *const FakeSource) []const u8 {
        return self.last_scope[0..self.last_scope_len];
    }

    fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator, scope: []const u8) TokenProvider.Error!Fetched {
        _ = io;
        const self: *FakeSource = @ptrCast(@alignCast(ptr));
        self.fetches += 1;
        self.last_scope_len = @min(scope.len, self.last_scope.len);
        @memcpy(self.last_scope[0..self.last_scope_len], scope[0..self.last_scope_len]);
        if (self.next >= self.replies.len) return error.TokenUnavailable;
        const reply = self.replies[self.next];
        self.next += 1;
        return switch (reply) {
            .fail => |err| err,
            // In the arena, as a parsed response would be.
            .token => |t| .{ .token = try arena.dupe(u8, t[0]), .expires_in = t[1], .refresh_in = t[2] },
        };
    }
};

/// A cache on a fake clock, and an arena for the copies it hands out.
const Setup = struct {
    clock: FakeClock,
    arena: std.heap.ArenaAllocator,
    cache: Cache,

    fn init(options: Options) !Setup {
        return .{ .clock = .{}, .arena = .init(testing.allocator), .cache = try .init(testing.allocator, options) };
    }

    fn deinit(s: *Setup) void {
        s.cache.deinit();
        s.arena.deinit();
    }

    fn get(s: *Setup, scope: []const u8, source: *FakeSource) TokenProvider.Error![]const u8 {
        return s.cache.getToken(s.clock.io(), s.arena.allocator(), scope, source.source());
    }

    fn advance(s: *Setup, seconds: i64) void {
        s.clock.now_ns += @as(i96, seconds) * std.time.ns_per_s;
    }
};

const arm = "https://management.core.windows.net//.default";
const blob = "https://storage.azure.com/.default";

test "Cache: fresh from memory, refreshed five minutes before expiry" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "t1", 3599, null } },
        .{ .token = .{ "t2", 3599, null } },
    } };
    try testing.expectEqualStrings("t1", try s.get(arm, &source));
    s.advance(3599 - 301);
    try testing.expectEqualStrings("t1", try s.get(arm, &source));
    try testing.expectEqual(1, source.fetches);
    s.advance(2);
    try testing.expectEqualStrings("t2", try s.get(arm, &source));
    try testing.expectEqual(2, source.fetches);
    try testing.expectEqualStrings(arm, source.lastScope());
}

test "Cache: a token per scope, each fetched and refreshed on its own" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "arm1", 3599, null } },
        .{ .token = .{ "blob1", 3599, null } },
        .{ .token = .{ "arm2", 3599, null } },
    } };
    try testing.expectEqualStrings("arm1", try s.get(arm, &source));
    s.advance(1000);
    try testing.expectEqualStrings("blob1", try s.get(blob, &source));
    try testing.expectEqualStrings(blob, source.lastScope());
    try testing.expectEqualStrings("arm1", try s.get(arm, &source));
    s.advance(2400);
    // ARM's is 3400 s old, within its margin; Storage's 2400 s, not.
    try testing.expectEqualStrings("arm2", try s.get(arm, &source));
    try testing.expectEqualStrings("blob1", try s.get(blob, &source));
    try testing.expectEqual(3, source.fetches);
}

test "Cache: refresh_in brings the refresh forward; a short life refreshes at half" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "t1", 86399, 43200 } },
        .{ .token = .{ "t2", 400, null } },
        .{ .token = .{ "t3", 400, null } },
    } };
    try testing.expectEqualStrings("t1", try s.get(arm, &source));
    s.advance(43199);
    try testing.expectEqualStrings("t1", try s.get(arm, &source));
    s.advance(1);
    try testing.expectEqualStrings("t2", try s.get(arm, &source));
    s.advance(199);
    try testing.expectEqualStrings("t2", try s.get(arm, &source));
    s.advance(1);
    try testing.expectEqualStrings("t3", try s.get(arm, &source));
}

test "Cache: a failed early refresh keeps the valid token, and tries again 30 s later" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "t1", 3600, null } },
        .{ .fail = error.TokenEndpointRejected },
        .{ .token = .{ "t2", 3600, null } },
    } };
    _ = try s.get(arm, &source);
    s.advance(3400);
    try testing.expectEqualStrings("t1", try s.get(arm, &source));
    try testing.expectEqual(2, source.fetches);
    s.advance(29);
    try testing.expectEqualStrings("t1", try s.get(arm, &source));
    try testing.expectEqual(2, source.fetches);
    s.advance(1);
    try testing.expectEqualStrings("t2", try s.get(arm, &source));
    try testing.expectEqual(3, source.fetches);
}

test "Cache: past expiry, or invalidated, a failed fetch is the error" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "t1", 600, null } },
        .{ .fail = error.TokenEndpointRejected },
        .{ .token = .{ "t2", 600, null } },
        .{ .fail = error.ReauthenticationRequired },
    } };
    _ = try s.get(arm, &source);
    s.advance(600);
    try testing.expectError(error.TokenEndpointRejected, s.get(arm, &source));
    try testing.expectEqualStrings("t2", try s.get(arm, &source));
    s.cache.invalidate();
    try testing.expectError(error.ReauthenticationRequired, s.get(arm, &source));
}

test "Cache: a token that is not a token, or has no life, is refused" {
    var s: Setup = try .init(.{});
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "a b", 3600, null } },
        .{ .token = .{ "t", 0, null } },
        .{ .token = .{ "", 3600, null } },
    } };
    for (0..3) |_| try testing.expectError(error.InvalidTokenResponse, s.get(arm, &source));
}

test "Cache: past max_scopes the oldest scope goes" {
    var s: Setup = try .init(.{ .max_scopes = 2 });
    defer s.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "a", 3600, null } },
        .{ .token = .{ "b", 3600, null } },
        .{ .token = .{ "c", 3600, null } },
        .{ .token = .{ "a2", 3600, null } },
    } };
    _ = try s.get("s1/.default", &source);
    _ = try s.get("s2/.default", &source);
    _ = try s.get("s3/.default", &source);
    try testing.expectEqual(2, s.cache.entries.items.len);
    try testing.expectEqualStrings("a2", try s.get("s1/.default", &source));
    try testing.expectEqual(4, source.fetches);
}

test "Cache: options that cannot work are refused" {
    for ([_]Options{ .{ .refresh_margin_s = 0 }, .{ .retry_delay_s = 0 }, .{ .max_lifetime_s = 300 }, .{ .max_scopes = 0 } }) |bad| {
        try testing.expectError(error.InvalidOptions, Cache.init(testing.allocator, bad));
    }
}

test "Cache: every block the cache frees is wiped first" {
    var checker: WipeChecker = .{ .child = testing.allocator };
    var clock: FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var source: FakeSource = .{ .replies = &.{
        .{ .token = .{ "t.one", 3600, null } },
        .{ .token = .{ "t.two", 3600, null } },
        .{ .token = .{ "t.three", 3600, null } },
        .{ .token = .{ "t.blob", 3600, null } },
    } };
    var cache: Cache = try .init(checker.allocator(), .{});
    _ = try cache.getToken(clock.io(), arena.allocator(), arm, source.source());
    clock.now_ns += 3400 * std.time.ns_per_s;
    _ = try cache.getToken(clock.io(), arena.allocator(), arm, source.source());
    cache.invalidate();
    _ = try cache.getToken(clock.io(), arena.allocator(), arm, source.source());
    _ = try cache.getToken(clock.io(), arena.allocator(), blob, source.source());
    cache.deinit();
    try testing.expect(checker.frees >= 8);
    try testing.expectEqual(0, checker.unwiped);
}
