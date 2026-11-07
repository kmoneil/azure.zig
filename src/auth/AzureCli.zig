//! The Azure CLI's login: `az account get-access-token --output json
//! --resource <resource> [--tenant <tenant>]`, run for each token, within
//! 10 s. For a developer's machine, where `az login` has been run; the
//! token is the signed-in user's or service principal's. Cached per scope,
//! and safe to share between tasks.
//!
//! az 2.54.0 and later print `expires_on`, epoch seconds (measured with
//! 2.92.0 on 2026-11-07); an older az prints only `expiresOn`, a local time
//! with no zone, which this refuses rather than guess the zone.

const AzureCli = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const core = @import("core");
const TokenProvider = core.TokenProvider;
const Cache = @import("Cache.zig");
const entra = @import("entra.zig");

const log = core.logging.Scoped(.azure_auth);

cache: Cache,
/// Owned, or null for the CLI's own default.
tenant: ?[]u8,
gpa: Allocator,
timeout_ms: u32,
diagnostics: ?*core.Diagnostics,
runner: Runner,

pub const Options = struct {
    /// Ask for a token in this tenant, as `--tenant` does; null: the one
    /// `az` is signed in to.
    tenant_id: ?[]const u8 = null,
    /// How long `az` may take.
    timeout_ms: u32 = 10_000,
    diagnostics: ?*core.Diagnostics = null,
    /// What runs `az`; null: the process itself, through `std.process.run`.
    runner: ?Runner = null,
    cache: Cache.Options = .{},
};

/// What `az` printed and how it ended.
pub const Output = struct {
    /// Its exit code, or null when a signal ended it.
    exit_code: ?u32,
    stdout: []const u8,
    stderr: []const u8,
};

pub const RunError = error{
    /// No `az` on the PATH.
    NotFound,
    /// It ran past its time and was killed.
    TimedOut,
    /// It could not be started, or its output could not be read.
    Failed,
    Canceled,
    OutOfMemory,
};

/// Runs a command and collects its output, allocated in `arena`.
pub const Runner = struct {
    ptr: ?*anyopaque = null,
    runFn: *const fn (ptr: ?*anyopaque, io: std.Io, arena: Allocator, argv: []const []const u8, timeout_ms: u32) RunError!Output,

    pub fn run(r: Runner, io: std.Io, arena: Allocator, argv: []const []const u8, timeout_ms: u32) RunError!Output {
        return r.runFn(r.ptr, io, arena, argv, timeout_ms);
    }

    /// The process itself.
    pub const system: Runner = .{ .runFn = runSystem };
};

fn runSystem(_: ?*anyopaque, io: std.Io, arena: Allocator, argv: []const []const u8, timeout_ms: u32) RunError!Output {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 16),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| return switch (err) {
        error.FileNotFound => error.NotFound,
        error.Timeout => error.TimedOut,
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
    return .{
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => null,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub const InitError = Allocator.Error || error{InvalidArgument};

pub fn init(gpa: Allocator, options: Options) InitError!AzureCli {
    if (options.tenant_id) |t| if (entra.tenantProblem(t) != null or !isArgument(t)) {
        if (options.diagnostics) |d| d.print("a tenant is its id or a domain: letters, digits, '.' and '-'", .{});
        return error.InvalidArgument;
    };
    const cache = Cache.init(gpa, options.cache) catch {
        if (options.diagnostics) |d| d.print("the cache's options cannot work", .{});
        return error.InvalidArgument;
    };
    return .{
        .gpa = gpa,
        .cache = cache,
        .tenant = if (options.tenant_id) |t| try gpa.dupe(u8, t) else null,
        .timeout_ms = options.timeout_ms,
        .diagnostics = options.diagnostics,
        .runner = options.runner orelse .system,
    };
}

pub fn deinit(self: *AzureCli) void {
    self.cache.deinit();
    if (self.tenant) |t| self.gpa.free(t);
    self.* = undefined;
}

/// The credential as every module takes it. It must outlive every client
/// given it.
pub fn provider(self: *AzureCli) TokenProvider {
    return .{ .ptr = self, .vtable = &.{ .getToken = getToken, .invalidate = invalidate } };
}

fn getToken(ptr: *anyopaque, io: std.Io, arena: Allocator, scopes: []const []const u8) TokenProvider.Error![]const u8 {
    const self: *AzureCli = @ptrCast(@alignCast(ptr));
    if (scopes.len != 1 or !entra.isAppScope(scopes[0]) or !isArgument(scopes[0])) {
        if (self.diagnostics) |d| d.print("the Azure CLI gives a token for one resource at a time: ask for its /.default scope", .{});
        return error.TokenUnavailable;
    }
    return self.cache.getToken(io, arena, scopes[0], .{ .ptr = self, .fetchFn = fetch });
}

fn invalidate(ptr: *anyopaque) void {
    const self: *AzureCli = @ptrCast(@alignCast(ptr));
    self.cache.invalidate();
}

/// Characters a URL or a tenant needs, and none a shell or `cmd.exe` reads
/// as its own: on Windows `az` is a batch file, which runs under `cmd.exe`.
fn isArgument(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, ":/._-~", c) != null)) return false;
    return true;
}

/// The command line for `resource`: `az` itself, or `cmd.exe /c az` on
/// Windows, which finds `az.cmd` as a shell would.
pub fn commandLine(arena: Allocator, resource: []const u8, tenant: ?[]const u8, windows: bool) Allocator.Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    if (windows) try args.appendSlice(arena, &.{ "cmd.exe", "/c" });
    try args.appendSlice(arena, &.{ "az", "account", "get-access-token", "--output", "json", "--resource", resource });
    if (tenant) |t| try args.appendSlice(arena, &.{ "--tenant", t });
    return args.items;
}

/// The resource a `/.default` scope names, as `--resource` takes it.
fn resourceOf(scope: []const u8) []const u8 {
    return scope[0 .. scope.len - "/.default".len];
}

fn fetch(ptr: *anyopaque, io: std.Io, arena: Allocator, scope: []const u8) TokenProvider.Error!Cache.Fetched {
    const self: *AzureCli = @ptrCast(@alignCast(ptr));
    const args = try commandLine(arena, resourceOf(scope), self.tenant, builtin.os.tag == .windows);
    const out = self.runner.run(io, arena, args, self.timeout_ms) catch |err| return self.runFailure(err);
    const code = out.exit_code orelse {
        self.say("az was ended by a signal", .{});
        return error.TokenUnavailable;
    };
    if (code != 0) return self.refusal(code, out.stderr);
    return self.parse(arena, out.stdout, std.Io.Clock.real.now(io).toSeconds());
}

fn runFailure(self: *AzureCli, err: RunError) TokenProvider.Error {
    switch (err) {
        error.NotFound => {
            self.say("az is not on the PATH: install the Azure CLI, or use another credential", .{});
            return error.CredentialSourceUnavailable;
        },
        error.TimedOut => {
            self.say("az took longer than {d} ms", .{self.timeout_ms});
            return error.TokenUnavailable;
        },
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        error.Failed => {
            self.say("az could not be run", .{});
            return error.TokenUnavailable;
        },
    }
}

/// What a failed `az` said: its first `ERROR:` line, which never holds a
/// token. A shell's or `cmd.exe`'s "not found" is no CLI at all. az ends
/// every AADSTS refusal with an `az login --tenant ... --scope ...` hint
/// (measured), so only an outright "Please run 'az login'" or a code that
/// means the sign-in itself lapsed asks for signing in again.
fn refusal(self: *AzureCli, code: u32, stderr: []const u8) TokenProvider.Error {
    const line = errorLine(stderr);
    if (code == 127 or code == 9009) {
        self.say("az is not on the PATH: install the Azure CLI, or use another credential", .{});
        return error.CredentialSourceUnavailable;
    }
    if (self.diagnostics) |d| d.set(0, "", line);
    log.debug("az exited {d}", .{code});
    for (relogin_signs) |sign| if (std.mem.indexOf(u8, stderr, sign) != null) return error.ReauthenticationRequired;
    return error.TokenEndpointRejected;
}

/// "Please run 'az login'"; a refresh token expired (700082) or revoked
/// (50173); multi-factor sign-in required again (50076, 50078).
const relogin_signs = [_][]const u8{ "Please run 'az login'", "AADSTS700082", "AADSTS50173", "AADSTS50076", "AADSTS50078" };

/// The first line that begins `ERROR:`, without it, or the first line.
fn errorLine(stderr: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    var first: ?[]const u8 = null;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue;
        if (first == null) first = line;
        if (std.mem.startsWith(u8, line, "ERROR:")) return std.mem.trim(u8, line["ERROR:".len..], " ");
    }
    return first orelse "az failed and said nothing";
}

fn parse(self: *AzureCli, arena: Allocator, stdout: []const u8, now_s: i64) TokenProvider.Error!Cache.Fetched {
    const Wire = struct {
        accessToken: ?[]const u8 = null,
        expires_on: ?std.json.Value = null,
        expiresOn: ?[]const u8 = null,
        tokenType: ?[]const u8 = null,
    };
    const wire = std.json.parseFromSliceLeaky(Wire, arena, stdout, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            self.say("az printed something other than its JSON", .{});
            return error.InvalidTokenResponse;
        },
    };
    const token = wire.accessToken orelse {
        self.say("az's answer has no accessToken", .{});
        return error.InvalidTokenResponse;
    };
    const on = expiresOn(wire.expires_on) orelse {
        if (wire.expiresOn != null) {
            self.say("this az gives only expiresOn, a local time with no zone: az 2.54.0 or later gives expires_on", .{});
        } else self.say("az's answer has no expires_on", .{});
        return error.InvalidTokenResponse;
    };
    return .{ .token = token, .expires_in = on - now_s };
}

fn expiresOn(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| n,
        .string, .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn say(self: *AzureCli, comptime fmt: []const u8, args: anytype) void {
    if (self.diagnostics) |d| d.print(fmt, args);
}

const testing = std.testing;

/// A runner that answers as `az` would, and keeps the command it was given.
const FakeAz = struct {
    exit_code: ?u32 = 0,
    stdout: []const u8 = "",
    stderr: []const u8 = "",
    fail: ?RunError = null,
    runs: usize = 0,
    last: [12][]const u8 = undefined,
    last_len: usize = 0,

    fn runner(self: *FakeAz) Runner {
        return .{ .ptr = self, .runFn = run };
    }

    fn run(ptr: ?*anyopaque, io: std.Io, arena: Allocator, args: []const []const u8, timeout_ms: u32) RunError!Output {
        _ = io;
        _ = timeout_ms;
        const self: *FakeAz = @ptrCast(@alignCast(ptr.?));
        self.runs += 1;
        self.last_len = @min(args.len, self.last.len);
        for (args[0..self.last_len], 0..) |a, i| self.last[i] = a;
        if (self.fail) |e| return e;
        return .{ .exit_code = self.exit_code, .stdout = try arena.dupe(u8, self.stdout), .stderr = self.stderr };
    }
};

/// az 2.92.0's answer on 2026-11-07 (t9's m0), the token and ids replaced.
const recorded_ok = "{\"accessToken\":\"eyJ0eXAiOiJKV1QifQ.e30.c2ln\",\"expiresOn\":\"2026-11-07 10:51:53.000000\",\"expires_on\":1794070313,\"subscription\":\"00000000-0000-4000-8000-000000000001\",\"tenant\":\"00000000-0000-4000-8000-000000000002\",\"tokenType\":\"Bearer\"}";

test "AzureCli: the command line, the token, its expiry from expires_on" {
    var fake: FakeAz = .{ .stdout = recorded_ok };
    var clock: core.testing.FakeClock = .{ .now_ns = 1_794_066_713 * std.time.ns_per_s };
    var cli: AzureCli = try .init(testing.allocator, .{ .runner = fake.runner(), .tenant_id = "contoso.onmicrosoft.com" });
    defer cli.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const p = cli.provider();
    try testing.expectEqualStrings("eyJ0eXAiOiJKV1QifQ.e30.c2ln", try p.getToken(clock.io(), arena.allocator(), &.{"https://management.core.windows.net//.default"}));
    const want = [_][]const u8{ "az", "account", "get-access-token", "--output", "json", "--resource", "https://management.core.windows.net/", "--tenant", "contoso.onmicrosoft.com" };
    const got = fake.last[0..fake.last_len];
    const skip: usize = if (builtin.os.tag == .windows) 2 else 0;
    try testing.expectEqual(want.len + skip, got.len);
    for (want, got[skip..]) |w, g| try testing.expectEqualStrings(w, g);
    // Cached: 3600 s to live, so no second run for some time.
    _ = try p.getToken(clock.io(), arena.allocator(), &.{"https://management.core.windows.net//.default"});
    try testing.expectEqual(1, fake.runs);
    clock.now_ns += 3400 * std.time.ns_per_s;
    _ = try p.getToken(clock.io(), arena.allocator(), &.{"https://management.core.windows.net//.default"});
    try testing.expectEqual(2, fake.runs);
}

test "AzureCli: no az, a login to run again, a refusal, a timeout, an old az" {
    var clock: core.testing.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const scope: []const []const u8 = &.{"https://storage.azure.com/.default"};
    const Case = struct { fake: FakeAz, err: TokenProvider.Error, says: []const u8 };
    for ([_]Case{
        .{ .fake = .{ .fail = error.NotFound }, .err = error.CredentialSourceUnavailable, .says = "az is not on the PATH" },
        .{ .fake = .{ .exit_code = 127 }, .err = error.CredentialSourceUnavailable, .says = "az is not on the PATH" },
        .{ .fake = .{ .exit_code = 1, .stderr = "ERROR: Please run 'az login' to setup account.\n" }, .err = error.ReauthenticationRequired, .says = "Please run 'az login' to setup account." },
        .{ .fake = .{ .exit_code = 1, .stderr = "ERROR: AADSTS500011: The resource principal named https://nothing.azzig.invalid was not found in the tenant named 00000000-0000-4000-8000-000000000002.\nRun the command below to authenticate interactively; additional arguments may be added as needed:\naz logout\naz login --tenant \"00000000-0000-4000-8000-000000000002\" --scope \"https://nothing.azzig.invalid/.default\"\n" }, .err = error.TokenEndpointRejected, .says = "AADSTS500011" },
        .{ .fake = .{ .exit_code = 1, .stderr = "ERROR: AADSTS700082: The refresh token has expired due to inactivity.\n" }, .err = error.ReauthenticationRequired, .says = "AADSTS700082" },
        .{ .fake = .{ .exit_code = 1, .stderr = "ERROR: Subscription not found.\n" }, .err = error.TokenEndpointRejected, .says = "Subscription not found." },
        .{ .fake = .{ .fail = error.TimedOut }, .err = error.TokenUnavailable, .says = "az took longer than 10000 ms" },
        .{ .fake = .{ .exit_code = null }, .err = error.TokenUnavailable, .says = "az was ended by a signal" },
        .{ .fake = .{ .stdout = "{\"accessToken\":\"t\",\"expiresOn\":\"2026-11-07 10:51:53.000000\",\"tokenType\":\"Bearer\"}" }, .err = error.InvalidTokenResponse, .says = "this az gives only expiresOn" },
        .{ .fake = .{ .stdout = "not json" }, .err = error.InvalidTokenResponse, .says = "az printed something other than its JSON" },
    }) |case| {
        var fake = case.fake;
        var diag: core.Diagnostics = .{};
        var cli: AzureCli = try .init(testing.allocator, .{ .runner = fake.runner(), .diagnostics = &diag });
        defer cli.deinit();
        try testing.expectError(case.err, cli.provider().getToken(clock.io(), arena.allocator(), scope));
        errdefer std.debug.print("said: {s}\n", .{diag.message()});
        try testing.expect(std.mem.indexOf(u8, diag.message(), case.says) != null);
    }
}

test "AzureCli: scopes and tenants that cannot go on a command line are refused before it runs" {
    var fake: FakeAz = .{ .stdout = recorded_ok };
    var clock: core.testing.FakeClock = .{};
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var cli: AzureCli = try .init(testing.allocator, .{ .runner = fake.runner() });
    defer cli.deinit();
    for ([_][]const []const u8{
        &.{},
        &.{ "https://storage.azure.com/.default", "https://management.core.windows.net//.default" },
        &.{"https://storage.azure.com/user_impersonation"},
        &.{"https://a.example/&calc/.default"},
        &.{"https://a.example/\"x/.default"},
    }) |scopes| try testing.expectError(error.TokenUnavailable, cli.provider().getToken(clock.io(), arena.allocator(), scopes));
    try testing.expectEqual(0, fake.runs);
    for ([_][]const u8{ "common", "a&b.com", "x" }) |t| try testing.expectError(error.InvalidArgument, AzureCli.init(testing.allocator, .{ .tenant_id = t }));
}
