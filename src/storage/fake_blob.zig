//! Blob Storage in memory, for code that uses the storage module:
//! containers and block blobs behind `Client.Options.transport`, answered
//! as production answered t14's m0 on 2026-11-07. Every XML body begins
//! with the byte order mark production sends; a create-only write over a
//! blob is 409 `BlobAlreadyExists`, any other unmet write condition 412
//! `ConditionNotMet`, a conditional read of a blob not there 404
//! `BlobNotFound`, and a range of an empty blob 416 `InvalidRange` with
//! `Content-Range: bytes */0`. Listings take `startFrom` inclusively and
//! name their next page by an opaque marker, and a page may come back
//! empty with a next one named, as production's may.
//!
//! It checks that a request is authorized (a token, or a `SharedKey`
//! header) and carries `x-ms-version` and `x-ms-date`, but not the
//! signature: Azurite and the live suite check that.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core");
const wire = core.transport;
const Header = wire.Header;

pub const FakeBlob = struct {
    arena: std.heap.ArenaAllocator,
    /// The endpoint the fake answers at: the client's
    /// (`.custom = .{ .url = base_url, .account = "azzigfake" }`).
    base_url: []const u8 = default_url,
    /// Entries in one page of a listing at most, below the service's 5000
    /// so that a test's listing takes pages.
    page_size: usize = 5000,
    /// Every this many pages, one page answers no entries and names a next
    /// one, as production may, but never two in a row. 0: never.
    empty_page_every: usize = 0,
    last_page_empty: bool = false,
    /// An account with a hierarchical namespace: its properties say so, and
    /// its listings hold directories.
    hierarchical: bool = false,
    /// The account's properties are refused 403, as a data role without
    /// the right to read them is.
    account_info_forbidden: bool = false,
    containers: std.ArrayList(Container) = .empty,
    /// Every request, in order.
    calls: std.ArrayList(Call) = .empty,
    /// The next request, or the next with `method`, is refused so, and
    /// changes nothing.
    fail_next: ?Failure = null,
    /// The next write to a blob (a put or a delete) is done, and then its
    /// answer is lost: the transport fails as a reset connection does.
    lose_next_answer: bool = false,
    /// The clock writes are stamped with, in Unix seconds; each write moves
    /// it on a second.
    clock: i64 = 1_793_000_000,
    next_etag: u64 = 0x8DF3CCF00000000,
    pages_served: usize = 0,
    next_request: u32 = 1,

    pub const default_url = "https://azzigfake.blob.core.windows.net";

    pub const Failure = struct {
        status: u16,
        code: []const u8,
        method: ?wire.Method = null,
    };

    pub const Call = struct {
        method: wire.Method,
        /// The path, percent-decoded, without the query.
        path: []const u8,
        query: []const u8,
    };

    pub const Metadata = struct { name: []const u8, value: []const u8 };

    pub const Blob = struct {
        name: []const u8,
        data: []const u8,
        /// Bare, as listings send it.
        etag: []const u8,
        content_type: []const u8,
        metadata: []const Metadata,
        created: i64,
        modified: i64,

        pub fn meta(b: Blob, name: []const u8) ?[]const u8 {
            for (b.metadata) |m| if (std.ascii.eqlIgnoreCase(m.name, name)) return m.value;
            return null;
        }
    };

    pub const Container = struct {
        name: []const u8,
        etag: []const u8,
        modified: i64,
        /// In name order.
        blobs: std.ArrayList(Blob) = .empty,

        pub fn find(c: *Container, name: []const u8) ?*Blob {
            return if (c.index(name)) |i| &c.blobs.items[i] else null;
        }

        fn index(c: *const Container, name: []const u8) ?usize {
            for (c.blobs.items, 0..) |b, i| if (std.mem.eql(u8, b.name, name)) return i;
            return null;
        }
    };

    pub fn init(gpa: Allocator) FakeBlob {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *FakeBlob) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn transport(self: *FakeBlob) wire.Transport {
        return .{ .ptr = self, .vtable = &.{ .send = send, .sendStream = sendStream } };
    }

    /// A container there before the test begins.
    pub fn addContainer(self: *FakeBlob, name: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        try self.containers.append(a, .{ .name = try a.dupe(u8, name), .etag = try self.newEtag(), .modified = self.tick() });
    }

    pub fn findContainer(self: *FakeBlob, name: []const u8) ?*Container {
        for (self.containers.items) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    /// The blob as the fake holds it now, or null.
    pub fn findBlob(self: *FakeBlob, container: []const u8, name: []const u8) ?*Blob {
        const c = self.findContainer(container) orelse return null;
        return c.find(name);
    }

    /// Writes a blob as an unconditional put would, before or during a
    /// test, as another writer does.
    pub fn putDirect(self: *FakeBlob, container: []const u8, name: []const u8, data: []const u8) Allocator.Error!void {
        const c = self.findContainer(container) orelse unreachable;
        try self.store(c, name, data, "application/octet-stream", &.{});
    }

    fn tick(self: *FakeBlob) i64 {
        self.clock += 1;
        return self.clock;
    }

    fn newEtag(self: *FakeBlob) Allocator.Error![]const u8 {
        self.next_etag += 1;
        return std.fmt.allocPrint(self.arena.allocator(), "0x{X}", .{self.next_etag});
    }

    fn store(self: *FakeBlob, c: *Container, name: []const u8, data: []const u8, content_type: []const u8, metadata: []const Metadata) Allocator.Error!void {
        const a = self.arena.allocator();
        const now = self.tick();
        const blob: Blob = .{
            .name = try a.dupe(u8, name),
            .data = try a.dupe(u8, data),
            .etag = try self.newEtag(),
            .content_type = try a.dupe(u8, content_type),
            .metadata = try copyMetadata(a, metadata),
            .created = if (c.find(name)) |old| old.created else now,
            .modified = now,
        };
        if (c.index(name)) |i| {
            c.blobs.items[i] = blob;
            return;
        }
        var at: usize = 0;
        while (at < c.blobs.items.len and std.mem.order(u8, c.blobs.items[at].name, name) == .lt) at += 1;
        try c.blobs.insert(a, at, blob);
    }

    fn copyMetadata(a: Allocator, metadata: []const Metadata) Allocator.Error![]const Metadata {
        const out = try a.alloc(Metadata, metadata.len);
        for (metadata, out) |m, *o| o.* = .{ .name = try a.dupe(u8, m.name), .value = try a.dupe(u8, m.value) };
        return out;
    }

    // The wire.

    const Answer = struct {
        status: u16 = 200,
        body: []const u8 = "",
        headers: []const Header = &.{},
        /// The write was done and its answer is to be lost.
        lost: bool = false,
    };

    /// What one request asks, read from the wire.
    const Asked = struct {
        method: wire.Method,
        container: ?[]const u8,
        blob: ?[]const u8,
        query: []const u8,
        headers: []const Header,
        content_type: ?[]const u8,
        body: []const u8,
        authorized: bool,

        fn header(q: Asked, name: []const u8) ?[]const u8 {
            for (q.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
            return null;
        }

        fn param(q: Asked, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
            var it = std.mem.splitScalar(u8, q.query, '&');
            while (it.next()) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
                if (!std.ascii.eqlIgnoreCase(pair[0..eq], name)) continue;
                const raw = if (eq < pair.len) pair[eq + 1 ..] else "";
                return try percentDecode(arena, raw) orelse raw;
            }
            return null;
        }
    };

    fn send(ptr: *anyopaque, req: wire.Request, arena: Allocator) wire.Error!wire.Response {
        _ = ptr;
        _ = req;
        _ = arena;
        // Every storage call streams.
        return error.HttpProtocolError;
    }

    fn sendStream(ptr: *anyopaque, req: wire.StreamRequest, arena: Allocator) wire.StreamError!wire.StreamResponse {
        const self: *FakeBlob = @ptrCast(@alignCast(ptr));
        const body: []const u8 = switch (req.body) {
            .none => "",
            .segments => |segments| try std.mem.concat(arena, u8, segments),
            .stream => return error.HttpProtocolError,
        };
        var got = try self.answer(arena, req, body);
        if (got.lost) return error.ConnectionResetByPeer;
        if (req.method == .HEAD) got.body = "";
        if (req.head_out) |out| out.* = .{ .status = got.status, .headers = got.headers };
        if (got.status < 300 and req.sink == .writer) {
            req.sink.writer.writeAll(got.body) catch return error.WriteFailed;
            return .{ .status = got.status, .headers = got.headers, .bytes_streamed = got.body.len };
        }
        return .{ .status = got.status, .headers = got.headers, .body = got.body };
    }

    fn answer(self: *FakeBlob, arena: Allocator, req: wire.StreamRequest, body: []const u8) Allocator.Error!Answer {
        if (!std.mem.startsWith(u8, req.url, self.base_url)) return self.refusal(arena, 400, "InvalidUri", "The requested URI does not represent any resource on the server.");
        const rest = req.url[self.base_url.len..];
        const q = std.mem.indexOfScalar(u8, rest, '?');
        const raw_path = rest[0 .. q orelse rest.len];
        const path = try percentDecode(arena, raw_path) orelse return self.refusal(arena, 400, "InvalidUri", "The requested URI does not represent any resource on the server.");
        const query = if (q) |i| rest[i + 1 ..] else "";
        const a = self.arena.allocator();
        try self.calls.append(a, .{ .method = req.method, .path = try a.dupe(u8, path), .query = try a.dupe(u8, query) });

        const trimmed = if (path.len > 0 and path[0] == '/') path[1..] else path;
        const slash = std.mem.indexOfScalar(u8, trimmed, '/');
        const asked: Asked = .{
            .method = req.method,
            .container = if (trimmed.len == 0) null else trimmed[0 .. slash orelse trimmed.len],
            .blob = if (slash) |i| trimmed[i + 1 ..] else null,
            .query = query,
            .headers = req.headers,
            .content_type = req.content_type,
            .body = body,
            .authorized = req.bearer != null or authorizedBySharedKey(req.headers),
        };
        if (try self.refused(arena, asked)) |no| return no;
        return self.route(arena, asked);
    }

    fn authorizedBySharedKey(sent: []const Header) bool {
        for (sent) |h| if (std.ascii.eqlIgnoreCase(h.name, "Authorization") and std.mem.startsWith(u8, h.value, "SharedKey ")) return true;
        return false;
    }

    /// A request refused before it is looked at: unauthorized, without the
    /// version or the date, or the failure a test asked for.
    fn refused(self: *FakeBlob, arena: Allocator, q: Asked) Allocator.Error!?Answer {
        if (!q.authorized) return try self.refusal(arena, 401, "NoAuthenticationInformation", "Server failed to authenticate the request. Please refer to the information in the www-authenticate header.");
        const v = q.header("x-ms-version") orelse return try self.refusal(arena, 400, "MissingRequiredHeader", "An HTTP header that's mandatory for this request is not specified.");
        if (!std.mem.eql(u8, v, "2026-04-06")) return try self.refusal(arena, 400, "InvalidHeaderValue", "The value for one of the HTTP headers is not in the correct format.");
        if (q.header("x-ms-date") == null) return try self.refusal(arena, 403, "AuthenticationFailed", "Server failed to authenticate the request. Make sure the value of Authorization header is formed correctly including the signature.");
        if (self.fail_next) |f| if (f.method == null or f.method.? == q.method) {
            self.fail_next = null;
            return try self.refusal(arena, f.status, f.code, "A failure the test asked for.");
        };
        return null;
    }

    fn route(self: *FakeBlob, arena: Allocator, q: Asked) Allocator.Error!Answer {
        const restype = try q.param(arena, "restype");
        const comp = try q.param(arena, "comp");
        const container_name = q.container orelse {
            if (eqlOpt(restype, "account") and eqlOpt(comp, "properties")) return self.accountProperties(arena);
            return self.refusal(arena, 400, "InvalidQueryParameterValue", "Value for one of the query parameters specified in the request URI is invalid.");
        };
        if (q.blob == null) {
            if (eqlOpt(restype, "container") and comp == null) return self.containerCall(arena, q, container_name);
            if (eqlOpt(restype, "container") and eqlOpt(comp, "list") and q.method == .GET) return self.list(arena, q, container_name);
            return self.refusal(arena, 400, "InvalidQueryParameterValue", "Value for one of the query parameters specified in the request URI is invalid.");
        }
        const c = self.findContainer(container_name) orelse return self.refusal(arena, 404, "ContainerNotFound", "The specified container does not exist.");
        if (comp != null) return self.refusal(arena, 400, "InvalidQueryParameterValue", "Value for one of the query parameters specified in the request URI is invalid.");
        return switch (q.method) {
            .PUT => self.putBlob(arena, q, c),
            .GET, .HEAD => self.getBlob(arena, q, c),
            .DELETE => self.deleteBlob(arena, q, c),
            else => self.refusal(arena, 400, "UnsupportedHttpVerb", "The resource doesn't support specified Http Verb."),
        };
    }

    fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
        return if (a) |x| std.mem.eql(u8, x, b) else false;
    }

    fn accountProperties(self: *FakeBlob, arena: Allocator) Allocator.Error!Answer {
        if (self.account_info_forbidden) return self.refusal(arena, 403, "AuthorizationPermissionMismatch", "This request is not authorized to perform this operation using this permission.");
        return .{ .headers = try self.common(arena, &.{
            .{ .name = "x-ms-sku-name", .value = "Standard_LRS" },
            .{ .name = "x-ms-account-kind", .value = "StorageV2" },
            .{ .name = "x-ms-is-hns-enabled", .value = if (self.hierarchical) "true" else "false" },
        }) };
    }

    // Containers.

    fn containerCall(self: *FakeBlob, arena: Allocator, q: Asked, name: []const u8) Allocator.Error!Answer {
        switch (q.method) {
            .PUT => {
                if (self.findContainer(name) != null) return self.refusal(arena, 409, "ContainerAlreadyExists", "The specified container already exists.");
                try self.addContainer(name);
                const c = self.findContainer(name).?;
                return .{ .status = 201, .headers = try self.stamped(arena, c.etag, c.modified, &.{}) };
            },
            .DELETE => {
                for (self.containers.items, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) {
                    _ = self.containers.orderedRemove(i);
                    return .{ .status = 202, .headers = try self.common(arena, &.{}) };
                };
                return self.refusal(arena, 404, "ContainerNotFound", "The specified container does not exist.");
            },
            .GET, .HEAD => {
                const c = self.findContainer(name) orelse return self.refusal(arena, 404, "ContainerNotFound", "The specified container does not exist.");
                return .{ .headers = try self.stamped(arena, c.etag, c.modified, &.{
                    .{ .name = "x-ms-lease-state", .value = "available" },
                    .{ .name = "x-ms-lease-status", .value = "unlocked" },
                    .{ .name = "x-ms-has-immutability-policy", .value = "false" },
                    .{ .name = "x-ms-has-legal-hold", .value = "false" },
                }) };
            },
            else => return self.refusal(arena, 400, "UnsupportedHttpVerb", "The resource doesn't support specified Http Verb."),
        }
    }

    // Blobs.

    /// The conditions a request carries, ETags bare.
    const Conditions = struct {
        if_match: ?[]const u8 = null,
        /// `*`, or a bare ETag.
        if_none_match: ?[]const u8 = null,
        if_modified_since: ?i64 = null,
        if_unmodified_since: ?i64 = null,

        fn of(q: Asked) Conditions {
            return .{
                .if_match = if (q.header("If-Match")) |v| unquote(v) else null,
                .if_none_match = if (q.header("If-None-Match")) |v| unquote(v) else null,
                .if_modified_since = if (q.header("If-Modified-Since")) |v| core.http_date.unixSeconds(v) else null,
                .if_unmodified_since = if (q.header("If-Unmodified-Since")) |v| core.http_date.unixSeconds(v) else null,
            };
        }
    };

    fn unquote(v: []const u8) []const u8 {
        return if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v[1 .. v.len - 1] else v;
    }

    /// What an unmet write condition answers, or null when every one is
    /// met. Create-only over a blob is 409, as production answers it.
    fn writeRefusal(self: *FakeBlob, arena: Allocator, existing: ?*const Blob, c: Conditions) Allocator.Error!?Answer {
        if (c.if_none_match) |v| if (std.mem.eql(u8, v, "*")) {
            if (existing != null) return try self.refusal(arena, 409, "BlobAlreadyExists", "The specified blob already exists.");
        } else if (existing) |b| if (std.mem.eql(u8, b.etag, v)) return try self.conditionNotMet(arena);
        if (c.if_match) |v| {
            const b = existing orelse return try self.conditionNotMet(arena);
            if (!std.mem.eql(u8, b.etag, v)) return try self.conditionNotMet(arena);
        }
        if (c.if_unmodified_since) |t| if (existing) |b| if (b.modified > t) return try self.conditionNotMet(arena);
        if (c.if_modified_since) |t| {
            const b = existing orelse return try self.conditionNotMet(arena);
            if (b.modified <= t) return try self.conditionNotMet(arena);
        }
        return null;
    }

    /// What an unmet read condition answers: 412 for `If-Match` and
    /// `If-Unmodified-Since`, 304 for `If-None-Match` and
    /// `If-Modified-Since`; null when every one is met.
    fn readRefusal(self: *FakeBlob, arena: Allocator, b: *const Blob, c: Conditions) Allocator.Error!?Answer {
        if (c.if_match) |v| if (!std.mem.eql(u8, b.etag, v)) return try self.conditionNotMet(arena);
        if (c.if_unmodified_since) |t| if (b.modified > t) return try self.conditionNotMet(arena);
        if (c.if_none_match) |v| if (std.mem.eql(u8, v, "*") or std.mem.eql(u8, b.etag, v)) return try self.notModified(arena, b);
        if (c.if_modified_since) |t| if (b.modified <= t) return try self.notModified(arena, b);
        return null;
    }

    fn conditionNotMet(self: *FakeBlob, arena: Allocator) Allocator.Error!Answer {
        return self.refusal(arena, 412, "ConditionNotMet", "The condition specified using HTTP conditional header(s) is not met.");
    }

    fn notModified(self: *FakeBlob, arena: Allocator, b: *const Blob) Allocator.Error!Answer {
        return .{ .status = 304, .headers = try self.stamped(arena, b.etag, b.modified, &.{}) };
    }

    fn putBlob(self: *FakeBlob, arena: Allocator, q: Asked, c: *Container) Allocator.Error!Answer {
        const name = q.blob.?;
        if (!eqlOpt(q.header("x-ms-blob-type"), "BlockBlob")) return self.refusal(arena, 400, "MissingRequiredHeader", "An HTTP header that's mandatory for this request is not specified.");
        if (q.header("x-ms-content-crc64")) |sent| {
            if (q.header("Content-MD5") != null) return self.refusal(arena, 400, "InvalidHeaderValue", "The value for one of the HTTP headers is not in the correct format.");
            const crc = core.crc64.toBase64(core.crc64.hash(q.body));
            if (!std.mem.eql(u8, sent, &crc)) return self.refusal(arena, 400, "Crc64Mismatch", "The CRC64 value specified in the request did not match with the CRC64 value calculated by the server.");
        }
        if (try self.writeRefusal(arena, c.find(name), .of(q))) |no| return no;
        var metadata: std.ArrayList(Metadata) = .empty;
        for (q.headers) |h| if (std.ascii.startsWithIgnoreCase(h.name, "x-ms-meta-")) {
            try metadata.append(arena, .{ .name = h.name["x-ms-meta-".len..], .value = h.value });
        };
        const content_type = q.header("x-ms-blob-content-type") orelse q.content_type orelse "application/octet-stream";
        try self.store(c, name, q.body, content_type, metadata.items);
        const b = c.find(name).?;
        if (self.lose_next_answer) {
            self.lose_next_answer = false;
            return .{ .lost = true };
        }
        const crc = core.crc64.toBase64(core.crc64.hash(b.data));
        return .{ .status = 201, .headers = try self.stamped(arena, b.etag, b.modified, &.{
            .{ .name = "Content-MD5", .value = try md5Of(arena, b.data) },
            .{ .name = "x-ms-content-crc64", .value = try arena.dupe(u8, &crc) },
            .{ .name = "x-ms-request-server-encrypted", .value = "true" },
        }) };
    }

    fn getBlob(self: *FakeBlob, arena: Allocator, q: Asked, c: *Container) Allocator.Error!Answer {
        const b = c.find(q.blob.?) orelse return self.refusal(arena, 404, "BlobNotFound", "The specified blob does not exist.");
        if (try self.readRefusal(arena, b, .of(q))) |no| return no;
        var extra: std.ArrayList(Header) = .empty;
        try extra.appendSlice(arena, &.{
            .{ .name = "Content-Type", .value = b.content_type },
            .{ .name = "x-ms-creation-time", .value = try httpDate(arena, b.created) },
            .{ .name = "x-ms-blob-type", .value = "BlockBlob" },
            .{ .name = "x-ms-lease-state", .value = "available" },
            .{ .name = "Accept-Ranges", .value = "bytes" },
        });
        for (b.metadata) |m| try extra.append(arena, .{ .name = try std.fmt.allocPrint(arena, "x-ms-meta-{s}", .{m.name}), .value = m.value });
        const range = q.header("x-ms-range") orelse q.header("Range");
        if (range == null or q.method == .HEAD) {
            try extra.append(arena, .{ .name = "Content-MD5", .value = try md5Of(arena, b.data) });
            try extra.append(arena, .{ .name = "Content-Length", .value = try std.fmt.allocPrint(arena, "{d}", .{b.data.len}) });
            return .{ .body = b.data, .headers = try self.stamped(arena, b.etag, b.modified, extra.items) };
        }
        const span = parseRange(range.?) orelse return self.refusal(arena, 400, "InvalidHeaderValue", "The value for one of the HTTP headers is not in the correct format.");
        if (span.start >= b.data.len) {
            const answer_range = try std.fmt.allocPrint(arena, "bytes */{d}", .{b.data.len});
            var no = try self.refusal(arena, 416, "InvalidRange", "The range specified is invalid for the current size of the resource.");
            no.headers = try std.mem.concat(arena, Header, &.{ no.headers, &.{.{ .name = "Content-Range", .value = answer_range }} });
            return no;
        }
        const end = @min(span.end orelse b.data.len - 1, b.data.len - 1);
        try extra.appendSlice(arena, &.{
            .{ .name = "Content-Range", .value = try std.fmt.allocPrint(arena, "bytes {d}-{d}/{d}", .{ span.start, end, b.data.len }) },
            .{ .name = "Content-Length", .value = try std.fmt.allocPrint(arena, "{d}", .{end - span.start + 1}) },
            .{ .name = "x-ms-blob-content-md5", .value = try md5Of(arena, b.data) },
        });
        return .{ .status = 206, .body = b.data[span.start .. end + 1], .headers = try self.stamped(arena, b.etag, b.modified, extra.items) };
    }

    const Span = struct { start: u64, end: ?u64 };

    /// `bytes=a-b` or `bytes=a-`.
    fn parseRange(text: []const u8) ?Span {
        if (!std.mem.startsWith(u8, text, "bytes=")) return null;
        const spec = text["bytes=".len..];
        const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
        const start = std.fmt.parseInt(u64, spec[0..dash], 10) catch return null;
        if (dash + 1 == spec.len) return .{ .start = start, .end = null };
        const end = std.fmt.parseInt(u64, spec[dash + 1 ..], 10) catch return null;
        if (end < start) return null;
        return .{ .start = start, .end = end };
    }

    fn deleteBlob(self: *FakeBlob, arena: Allocator, q: Asked, c: *Container) Allocator.Error!Answer {
        const i = c.index(q.blob.?) orelse return self.refusal(arena, 404, "BlobNotFound", "The specified blob does not exist.");
        if (try self.writeRefusal(arena, &c.blobs.items[i], .of(q))) |no| return no;
        _ = c.blobs.orderedRemove(i);
        _ = self.tick();
        if (self.lose_next_answer) {
            self.lose_next_answer = false;
            return .{ .lost = true };
        }
        return .{ .status = 202, .headers = try self.common(arena, &.{.{ .name = "x-ms-delete-type-permanent", .value = "true" }}) };
    }

    // Listings.

    const Entry = struct {
        name: []const u8,
        blob: ?*const Blob,
        kind: enum { blob, prefix, directory },
    };

    fn list(self: *FakeBlob, arena: Allocator, q: Asked, name: []const u8) Allocator.Error!Answer {
        const c = self.findContainer(name) orelse return self.refusal(arena, 404, "ContainerNotFound", "The specified container does not exist.");
        const prefix = try q.param(arena, "prefix") orelse "";
        const delimiter = try q.param(arena, "delimiter");
        const start_from = try q.param(arena, "startFrom");
        const marker = try q.param(arena, "marker") orelse "";
        const with_metadata = if (try q.param(arena, "include")) |inc| std.mem.indexOf(u8, inc, "metadata") != null else false;
        const max = if (try q.param(arena, "maxresults")) |m| std.fmt.parseInt(usize, m, 10) catch 0 else 5000;
        if (max == 0 or max > 5000) return self.refusal(arena, 400, "OutOfRangeQueryParameterValue", "One of the query parameters specified in the request URI is outside the permissible range.");

        const entries = try self.listEntries(arena, c, prefix, delimiter, start_from);
        const from_name = try decodeMarker(arena, marker);
        var first: usize = 0;
        if (from_name) |n| while (first < entries.len and std.mem.order(u8, entries[first].name, n) == .lt) : (first += 1) {};
        self.pages_served += 1;
        const empty = self.empty_page_every > 0 and self.pages_served % self.empty_page_every == 0 and first < entries.len and !self.last_page_empty;
        self.last_page_empty = empty;
        const take = if (empty) 0 else @min(entries.len - first, @min(max, self.page_size));
        const next = if (first + take < entries.len) entries[first + take].name else null;
        return .{ .headers = try self.common(arena, &.{.{ .name = "Content-Type", .value = "application/xml" }}), .body = try self.listingBody(arena, c, prefix, delimiter, marker, entries[first .. first + take], next, with_metadata) };
    }

    /// The listing's entries in name order: blobs under `prefix` from
    /// `start_from` on, those past a delimiter grouped into one prefix
    /// each, and in a hierarchical account the directories.
    fn listEntries(self: *FakeBlob, arena: Allocator, c: *Container, prefix: []const u8, delimiter: ?[]const u8, start_from: ?[]const u8) Allocator.Error![]Entry {
        var out: std.ArrayList(Entry) = .empty;
        for (c.blobs.items) |*b| {
            if (!std.mem.startsWith(u8, b.name, prefix)) continue;
            if (start_from) |s| if (std.mem.order(u8, b.name, s) == .lt) continue;
            if (delimiter) |d| if (std.mem.indexOf(u8, b.name[prefix.len..], d)) |at| {
                const group = b.name[0 .. prefix.len + at + d.len];
                if (out.items.len == 0 or !std.mem.eql(u8, out.items[out.items.len - 1].name, group)) try out.append(arena, .{ .name = group, .blob = null, .kind = .prefix });
                continue;
            };
            try out.append(arena, .{ .name = b.name, .blob = b, .kind = .blob });
        }
        if (self.hierarchical and delimiter == null) try addDirectories(arena, &out, prefix);
        std.mem.sort(Entry, out.items, {}, entryLess);
        return out.items;
    }

    fn addDirectories(arena: Allocator, out: *std.ArrayList(Entry), prefix: []const u8) Allocator.Error!void {
        const count = out.items.len;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const e = out.items[i];
            var at: usize = prefix.len;
            while (std.mem.indexOfScalarPos(u8, e.name, at, '/')) |slash| : (at = slash + 1) {
                const dir = e.name[0..slash];
                const seen = for (out.items) |o| {
                    if (o.kind == .directory and std.mem.eql(u8, o.name, dir)) break true;
                } else false;
                if (!seen) try out.append(arena, .{ .name = dir, .blob = null, .kind = .directory });
            }
        }
    }

    fn entryLess(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    /// Markers are opaque in production; the fake's are the next entry's
    /// name, hex-encoded behind a tag.
    fn encodeMarker(arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "2!fake!");
        for (name) |byte| try out.print(arena, "{X:0>2}", .{byte});
        return out.items;
    }

    fn decodeMarker(arena: Allocator, marker: []const u8) Allocator.Error!?[]const u8 {
        if (!std.mem.startsWith(u8, marker, "2!fake!")) return null;
        const hex = marker["2!fake!".len..];
        if (hex.len % 2 != 0) return null;
        const out = try arena.alloc(u8, hex.len / 2);
        return std.fmt.hexToBytes(out, hex) catch null;
    }

    fn listingBody(
        self: *FakeBlob,
        arena: Allocator,
        c: *const Container,
        prefix: []const u8,
        delimiter: ?[]const u8,
        marker: []const u8,
        page: []const Entry,
        next: ?[]const u8,
        with_metadata: bool,
    ) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        const w = &out.writer;
        writeListing(w, arena, self.base_url, c, prefix, delimiter, marker, page, next, with_metadata) catch return error.OutOfMemory;
        return out.written();
    }

    fn writeListing(
        w: *std.Io.Writer,
        arena: Allocator,
        base_url: []const u8,
        c: *const Container,
        prefix: []const u8,
        delimiter: ?[]const u8,
        marker: []const u8,
        page: []const Entry,
        next: ?[]const u8,
        with_metadata: bool,
    ) (std.Io.Writer.Error || Allocator.Error)!void {
        try w.print(bom ++ "<?xml version=\"1.0\" encoding=\"utf-8\"?><EnumerationResults ServiceEndpoint=\"{s}/\" ContainerName=\"{s}\">", .{ base_url, c.name });
        try w.writeAll("<Prefix>");
        try writeText(w, prefix);
        try w.writeAll("</Prefix><Marker>");
        try writeText(w, marker);
        try w.writeAll("</Marker>");
        if (delimiter) |d| {
            try w.writeAll("<Delimiter>");
            try writeText(w, d);
            try w.writeAll("</Delimiter>");
        }
        try w.writeAll("<Blobs>");
        for (page) |e| try writeEntry(w, arena, e, with_metadata);
        try w.writeAll("</Blobs><NextMarker>");
        if (next) |n| try w.writeAll(try encodeMarker(arena, n));
        try w.writeAll("</NextMarker></EnumerationResults>");
    }

    fn writeEntry(w: *std.Io.Writer, arena: Allocator, e: Entry, with_metadata: bool) (std.Io.Writer.Error || Allocator.Error)!void {
        try w.writeAll(if (e.kind == .prefix) "<BlobPrefix>" else "<Blob>");
        try writeName(w, e.name);
        switch (e.kind) {
            .prefix => return w.writeAll("</BlobPrefix>"),
            .directory => return w.writeAll("<Properties><Content-Length>0</Content-Length><Etag>0x8DF0000000000000</Etag><ResourceType>directory</ResourceType></Properties></Blob>"),
            .blob => {},
        }
        const b = e.blob.?;
        try w.print("<Properties><Creation-Time>{s}</Creation-Time><Last-Modified>{s}</Last-Modified><Etag>{s}</Etag><Content-Length>{d}</Content-Length><Content-Type>", .{ try httpDate(arena, b.created), try httpDate(arena, b.modified), b.etag, b.data.len });
        try writeText(w, b.content_type);
        try w.print("</Content-Type><Content-MD5>{s}</Content-MD5><BlobType>BlockBlob</BlobType><LeaseStatus>unlocked</LeaseStatus><LeaseState>available</LeaseState></Properties>", .{try md5Of(arena, b.data)});
        if (with_metadata) {
            try w.writeAll("<Metadata>");
            for (b.metadata) |m| {
                try w.print("<{s}>", .{m.name});
                try writeText(w, m.value);
                try w.print("</{s}>", .{m.name});
            }
            try w.writeAll("</Metadata>");
        }
        try w.writeAll("</Blob>");
    }

    /// A name XML 1.0 can hold as text, or percent-encoded with
    /// `Encoded="true"` when it holds U+FFFE or U+FFFF, as the service does.
    fn writeName(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
        if (std.mem.indexOf(u8, name, "\xef\xbf\xbe") != null or std.mem.indexOf(u8, name, "\xef\xbf\xbf") != null) {
            try w.writeAll("<Name Encoded=\"true\">");
            for (name) |byte| {
                if (core.query.isUnreserved(byte) or byte == '/') try w.writeByte(byte) else try w.print("%{X:0>2}", .{byte});
            }
            return w.writeAll("</Name>");
        }
        try w.writeAll("<Name>");
        try writeText(w, name);
        try w.writeAll("</Name>");
    }

    fn writeText(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
        for (text) |c| switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            else => try w.writeByte(c),
        };
    }

    // Answers.

    const bom = "\xef\xbb\xbf";

    /// A refusal as production sends one: the code in `x-ms-error-code`,
    /// and an XML body after the byte order mark.
    fn refusal(self: *FakeBlob, arena: Allocator, status: u16, code: []const u8, message: []const u8) Allocator.Error!Answer {
        const id = try self.requestId(arena);
        return .{
            .status = status,
            .body = try std.fmt.allocPrint(arena, bom ++ "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>{s}</Code><Message>{s}\nRequestId:{s}\nTime:2026-11-07T13:00:00.0000000Z</Message></Error>", .{ code, message, id }),
            .headers = try arena.dupe(Header, &.{
                .{ .name = "Content-Type", .value = "application/xml" },
                .{ .name = "x-ms-error-code", .value = code },
                .{ .name = "x-ms-request-id", .value = id },
                .{ .name = "x-ms-version", .value = "2026-04-06" },
            }),
        };
    }

    fn requestId(self: *FakeBlob, arena: Allocator) Allocator.Error![]const u8 {
        defer self.next_request += 1;
        return std.fmt.allocPrint(arena, "fake-{d}", .{self.next_request});
    }

    /// The headers every answer carries, then `extra`.
    fn common(self: *FakeBlob, arena: Allocator, extra: []const Header) Allocator.Error![]const Header {
        return std.mem.concat(arena, Header, &.{ &.{
            .{ .name = "x-ms-request-id", .value = try self.requestId(arena) },
            .{ .name = "x-ms-version", .value = "2026-04-06" },
        }, extra });
    }

    /// `headers` with a resource's ETag, quoted, and Last-Modified.
    fn stamped(self: *FakeBlob, arena: Allocator, etag: []const u8, modified: i64, extra: []const Header) Allocator.Error![]const Header {
        return self.common(arena, try std.mem.concat(arena, Header, &.{ &.{
            .{ .name = "ETag", .value = try std.fmt.allocPrint(arena, "\"{s}\"", .{etag}) },
            .{ .name = "Last-Modified", .value = try httpDate(arena, modified) },
        }, extra }));
    }

    fn httpDate(arena: Allocator, seconds: i64) Allocator.Error![]const u8 {
        var buf: [core.http_date.len]u8 = undefined;
        return arena.dupe(u8, core.http_date.format(&buf, .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s }));
    }

    fn md5Of(arena: Allocator, data: []const u8) Allocator.Error![]const u8 {
        var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        std.crypto.hash.Md5.hash(data, &digest, .{});
        const out = try arena.alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
        _ = std.base64.standard.Encoder.encode(out, &digest);
        return out;
    }

    fn percentDecode(arena: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '%') {
                try out.append(arena, text[i]);
                continue;
            }
            if (i + 2 >= text.len) return null;
            try out.append(arena, std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null);
            i += 2;
        }
        return out.items;
    }
};
