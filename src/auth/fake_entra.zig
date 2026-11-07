//! Entra ID's v2 token endpoint in memory, for code that signs an app in
//! with a client secret: tenants and their apps, behind
//! `ClientSecret.Options.transport`. It answers as Entra answered t9's m0
//! on 2026-11-07: `{"token_type":"Bearer","expires_in":3599,
//! "ext_expires_in":3599,"access_token":...}`, and each refusal with its
//! status, error, AADSTS code, and trace and correlation ids.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const wire = core.transport;

pub const FakeEntra = struct {
    arena: std.heap.ArenaAllocator,
    /// The authority host the fake answers at, with its trailing slash.
    authority_host: []const u8 = core.Cloud.public.authority_host,
    apps: std.ArrayList(App) = .empty,
    /// What every token says it lives.
    expires_in: i64 = 3599,
    /// Sent with every token when set, as a long-lived one carries it.
    refresh_in: ?i64 = null,
    /// The next request is answered so, and issues nothing.
    fail_next: ?Failure = null,
    /// Every token issued, in order: its scope.
    issued: std.ArrayList([]const u8) = .empty,
    requests: usize = 0,

    pub const App = struct {
        tenant: []const u8,
        client_id: []const u8,
        secret: []const u8,
    };

    pub const Failure = struct {
        status: u16,
        /// An Entra error body; empty for a gateway's page.
        body: []const u8 = "",
        headers: []const wire.Header = &.{},
    };

    pub fn init(gpa: Allocator) FakeEntra {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *FakeEntra) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// An app registered in `tenant`, with one secret.
    pub fn addApp(self: *FakeEntra, tenant: []const u8, client_id: []const u8, secret: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        try self.apps.append(a, .{ .tenant = try a.dupe(u8, tenant), .client_id = try a.dupe(u8, client_id), .secret = try a.dupe(u8, secret) });
    }

    pub fn transport(self: *FakeEntra) wire.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    fn sendStream(ptr: *anyopaque, req: wire.StreamRequest, arena: Allocator) wire.StreamError!wire.StreamResponse {
        _ = ptr;
        _ = req;
        _ = arena;
        // A token request is a small form, sent buffered.
        return error.HttpProtocolError;
    }

    fn send(ptr: *anyopaque, req: wire.Request, arena: Allocator) wire.Error!wire.Response {
        const self: *FakeEntra = @ptrCast(@alignCast(ptr));
        self.requests += 1;
        if (self.fail_next) |f| {
            self.fail_next = null;
            return .{ .status = f.status, .body = try arena.dupe(u8, f.body), .headers = try arena.dupe(wire.Header, f.headers) };
        }
        return self.answer(arena, req);
    }

    fn answer(self: *FakeEntra, arena: Allocator, req: wire.Request) Allocator.Error!wire.Response {
        const tenant = tenantOf(self.authority_host, req.url) orelse return refusal(arena, 404, "invalid_request", 90002, "AADSTS90002: The token endpoint is not this fake's.");
        if (req.method != .POST or req.content_type != .form) return refusal(arena, 405, "invalid_request", 900561, "AADSTS900561: The endpoint only accepts POST requests.");
        const body = req.body orelse "";
        const grant = try field(arena, body, "grant_type") orelse "";
        if (!std.mem.eql(u8, grant, "client_credentials")) return refusal(arena, 400, "unsupported_grant_type", 70003, "AADSTS70003: The app requested an unsupported grant type.");
        const client_id = try field(arena, body, "client_id") orelse "";
        const scope = try field(arena, body, "scope") orelse "";
        if (!std.mem.endsWith(u8, scope, "/.default")) {
            return refusal(arena, 400, "invalid_scope", 1002012, try std.fmt.allocPrint(arena, "AADSTS1002012: The provided value for scope {s} is not valid. Client credential flows must have a scope value with /.default suffixed to the resource identifier (application ID URI).", .{scope}));
        }
        const app = self.find(tenant, client_id) orelse {
            if (!self.knowsTenant(tenant)) return refusal(arena, 400, "invalid_request", 90002, try std.fmt.allocPrint(arena, "AADSTS90002: Tenant '{s}' not found. Check to make sure you have the correct tenant ID and are signing into the correct cloud.", .{tenant}));
            return refusal(arena, 400, "unauthorized_client", 700016, try std.fmt.allocPrint(arena, "AADSTS700016: Application with identifier '{s}' was not found in the directory '{s}'.", .{ client_id, tenant }));
        };
        const secret = try field(arena, body, "client_secret") orelse "";
        if (!std.mem.eql(u8, secret, app.secret)) {
            return refusal(arena, 401, "invalid_client", 7000215, try std.fmt.allocPrint(arena, "AADSTS7000215: Invalid client secret provided. Ensure the secret being sent in the request is the client secret value, not the client secret ID, for a secret added to app '{s}'.", .{app.client_id}));
        }
        const a = self.arena.allocator();
        try self.issued.append(a, try a.dupe(u8, scope));
        var out: std.Io.Writer.Allocating = .init(arena);
        out.writer.print("{{\"token_type\":\"Bearer\",\"expires_in\":{d},\"ext_expires_in\":{d},", .{ self.expires_in, self.expires_in }) catch return error.OutOfMemory;
        if (self.refresh_in) |r| out.writer.print("\"refresh_in\":{d},", .{r}) catch return error.OutOfMemory;
        out.writer.print("\"access_token\":\"fake-entra.{d}\"}}", .{self.issued.items.len}) catch return error.OutOfMemory;
        return .{ .status = 200, .body = out.written(), .headers = try arena.dupe(wire.Header, &.{.{ .name = "Content-Type", .value = "application/json; charset=utf-8" }}) };
    }

    fn find(self: *FakeEntra, tenant: []const u8, client_id: []const u8) ?App {
        for (self.apps.items) |app| if (std.ascii.eqlIgnoreCase(app.tenant, tenant) and std.ascii.eqlIgnoreCase(app.client_id, client_id)) return app;
        return null;
    }

    fn knowsTenant(self: *FakeEntra, tenant: []const u8) bool {
        for (self.apps.items) |app| if (std.ascii.eqlIgnoreCase(app.tenant, tenant)) return true;
        return false;
    }

    /// The tenant of `{authority_host}{tenant}/oauth2/v2.0/token`.
    fn tenantOf(host: []const u8, url: []const u8) ?[]const u8 {
        if (!std.mem.startsWith(u8, url, host)) return null;
        const rest = url[host.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        if (!std.mem.eql(u8, rest[slash..], "/oauth2/v2.0/token")) return null;
        return rest[0..slash];
    }

    /// A form field, decoded.
    fn field(arena: Allocator, body: []const u8, name: []const u8) Allocator.Error!?[]const u8 {
        var pairs = std.mem.splitScalar(u8, body, '&');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            if (!std.mem.eql(u8, pair[0..eq], name)) continue;
            const value = try arena.dupe(u8, pair[eq + 1 ..]);
            return std.Uri.percentDecodeInPlace(value);
        }
        return null;
    }

    /// Entra's error body, its ids made up and repeated in the description
    /// as Entra repeats them.
    fn refusal(arena: Allocator, status: u16, code: []const u8, aadsts: u32, description: []const u8) Allocator.Error!wire.Response {
        const trace = "00000000-0000-4000-8000-0000000000e1";
        const correlation = "00000000-0000-4000-8000-0000000000c1";
        var out: std.Io.Writer.Allocating = .init(arena);
        var json: std.json.Stringify = .{ .writer = &out.writer };
        writeRefusal(&json, code, aadsts, description, trace, correlation) catch return error.OutOfMemory;
        return .{ .status = status, .body = out.written(), .headers = try arena.dupe(wire.Header, &.{
            .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
            .{ .name = "x-ms-request-id", .value = trace },
        }) };
    }

    fn writeRefusal(json: *std.json.Stringify, code: []const u8, aadsts: u32, description: []const u8, trace: []const u8, correlation: []const u8) !void {
        try json.beginObject();
        try json.objectField("error");
        try json.write(code);
        try json.objectField("error_description");
        var buf: [1024]u8 = undefined;
        try json.write(try std.fmt.bufPrint(&buf, "{s} Trace ID: {s} Correlation ID: {s} Timestamp: 2026-11-07 15:46:22Z", .{ description, trace, correlation }));
        try json.objectField("error_codes");
        try json.write(&[_]u32{aadsts});
        try json.objectField("timestamp");
        try json.write("2026-11-07 15:46:22Z");
        try json.objectField("trace_id");
        try json.write(trace);
        try json.objectField("correlation_id");
        try json.write(correlation);
        try json.endObject();
    }
};
