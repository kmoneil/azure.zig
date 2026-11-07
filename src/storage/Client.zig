//! The storage client: containers and blobs in one account, on Blob
//! Storage's REST API at x-ms-version 2026-04-06. Made with `init`, freed
//! with `deinit`; one task uses it at a time.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const core = @import("core");
const transport = core.transport;
const Header = transport.Header;
const hook = @import("hook.zig");
const shared_key = @import("shared_key.zig");
const types = @import("types.zig");
const validate = @import("validate.zig");
const xml = @import("xml.zig");

const Etag = types.Etag;
const Owned = types.Owned;
const log = core.logging.Scoped(.azure_storage);

/// The x-ms-version every call sends: the newest deployed in every region
/// on 2026-11-06, and one Azurite 3.37.0 accepts.
pub const version = "2026-04-06";

/// A Shared Key signature is good for 15 minutes after its `x-ms-date`.
/// The client signs a call once, so no retry of it begins later than this
/// after its first attempt, which leaves five minutes for the clocks to
/// differ.
pub const signed_retry_window_ms = 10 * 60 * 1000;

/// Pages read at most for one listing, a guard against a server whose
/// `NextMarker` never ends.
pub const max_pages = 10_000;

gpa: Allocator,
io: std.Io,
engine: hook.Engine,
/// The transport the client made, when its options named none.
http: ?*transport.HttpTransport,
/// The account, as signed.
account: []const u8,
/// `/{account}` for a path-style endpoint, else empty.
path_prefix: []const u8,
/// Base URL and path prefix, in one allocation.
owned: []u8,
/// The decoded account key, for Shared Key; null with a token.
key: ?shared_key.Key,
check_namespace: bool,
namespace: Namespace = .unchecked,

const Namespace = enum { unchecked, flat, hierarchical, unknown };

pub const Options = struct {
    endpoint: types.Endpoint,
    credential: types.Credential,
    /// Null: a `std.http.Client` transport of the client's own.
    transport: ?transport.Transport = null,
    /// Details of the latest failed call.
    diagnostics: ?*core.Diagnostics = null,
    retry: core.RetryPolicy = hook.retry_policy,
    /// How long one attempt may take; 0 removes the limit.
    request_timeout_ms: u32 = 60_000,
    user_agent: []const u8 = "azure.zig",
    /// Read the account's properties before the first call, and refuse an
    /// account with a hierarchical namespace (ADLS Gen2), whose listings
    /// hold directories and whose deletes leave them, with
    /// `HierarchicalNamespace`.
    check_hierarchical_namespace: bool = true,
};

pub const Error = hook.Engine.Error || error{
    /// An argument refused before anything is sent: a name Blob Storage
    /// would refuse or change, metadata it would not read back as sent,
    /// conditions a write cannot carry. `Diagnostics` says which.
    InvalidArgument,
    /// An answer that is not what Blob Storage sends. `Diagnostics` says
    /// which.
    InvalidResponse,
    /// The account has a hierarchical namespace, which this client refuses.
    HierarchicalNamespace,
};

pub const InitError = Allocator.Error || error{InvalidArgument};

pub fn init(gpa: Allocator, io: std.Io, options: Options) InitError!Client {
    const account = options.endpoint.accountName();
    if (!isAccountName(account)) return invalidAtInit(options.diagnostics, "a storage account name is 3 to 24 lowercase letters and digits");
    const key: ?shared_key.Key = switch (options.credential) {
        .token => null,
        .shared_key => |text| shared_key.Key.decode(text) catch return invalidAtInit(options.diagnostics, "the account key is not the base64 of 1 to 128 bytes"),
    };
    const base, const prefix = switch (options.endpoint) {
        .account => |a| .{ try std.fmt.allocPrint(gpa, "https://{s}.blob.{s}", .{ a.name, a.cloud.storage_suffix }), false },
        .azurite => |a| .{ try gpa.dupe(u8, a.url), true },
        .custom => |c| .{ try gpa.dupe(u8, c.url), c.path_style },
    };
    defer gpa.free(base);
    if (!isBaseUrl(base)) return invalidAtInit(options.diagnostics, "an endpoint URL is http:// or https://, a host, and no path or trailing slash");
    const owned = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ base, if (prefix) "/" else "", if (prefix) account else "" });
    errdefer gpa.free(owned);

    var http: ?*transport.HttpTransport = null;
    const t = options.transport orelse t: {
        const h = try gpa.create(transport.HttpTransport);
        h.* = .init(gpa, io, options.user_agent);
        http = h;
        break :t h.transport();
    };
    return .{
        .gpa = gpa,
        .io = io,
        .http = http,
        .account = account,
        .owned = owned,
        .path_prefix = owned[base.len..],
        .key = key,
        .check_namespace = options.check_hierarchical_namespace,
        .engine = .{
            .gpa = gpa,
            .io = io,
            .transport = t,
            .base_url = owned[0..base.len],
            .auth_scope = core.Cloud.storage_scope,
            .token_provider = switch (options.credential) {
                .token => |p| p,
                .shared_key => null,
            },
            .diagnostics = options.diagnostics,
            .retry = options.retry,
            .request_timeout_ms = options.request_timeout_ms,
        },
    };
}

fn invalidAtInit(diagnostics: ?*core.Diagnostics, comptime why: []const u8) error{InvalidArgument} {
    if (diagnostics) |d| d.print(why, .{});
    return error.InvalidArgument;
}

pub fn deinit(self: *Client) void {
    if (self.http) |h| {
        h.deinit();
        self.gpa.destroy(h);
    }
    if (self.key) |*k| std.crypto.secureZero(u8, &k.bytes);
    self.gpa.free(self.owned);
    self.* = undefined;
}

/// 3 to 24 lowercase letters and digits.
fn isAccountName(name: []const u8) bool {
    if (name.len < 3 or name.len > 24) return false;
    for (name) |c| if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9'))) return false;
    return true;
}

fn isBaseUrl(url: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, url, "https://"))
        url["https://".len..]
    else if (std.mem.startsWith(u8, url, "http://"))
        url["http://".len..]
    else
        return false;
    if (rest.len == 0) return false;
    for (rest) |c| if (c == '/' or c == '?' or c == '#' or c == '@' or c <= ' ' or c >= 0x7f) return false;
    return true;
}

// Containers.

/// Makes the container: true when it was made, false when it was there
/// already. One being deleted is `Conflict`; its name is free again 30
/// seconds or more after the delete.
pub fn createContainer(self: *Client, name: []const u8) Error!bool {
    self.engine.begin();
    try self.checkContainer(name);
    try self.ensureFlat();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    _ = self.send(&response, scratch.allocator(), .{
        .method = .PUT,
        .container = name,
        .query = &.{.{ .name = "restype", .value = "container" }},
    }) catch |err| switch (err) {
        error.ContainerAlreadyExists => return false,
        else => |e| return e,
    };
    return true;
}

/// Deletes the container and every blob in it: true when there was one,
/// false when there was none. Its blobs may still read for up to 30
/// seconds.
pub fn deleteContainer(self: *Client, name: []const u8) Error!bool {
    self.engine.begin();
    try self.checkContainer(name);
    try self.ensureFlat();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    _ = self.send(&response, scratch.allocator(), .{
        .method = .DELETE,
        .container = name,
        .query = &.{.{ .name = "restype", .value = "container" }},
    }) catch |err| switch (err) {
        error.ContainerNotFound => return false,
        else => |e| return e,
    };
    return true;
}

/// The container's properties; `ContainerNotFound` when there is none.
pub fn getContainerProperties(self: *Client, name: []const u8) Error!Owned(types.ContainerProperties) {
    self.engine.begin();
    try self.checkContainer(name);
    try self.ensureFlat();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    var out: Owned(types.ContainerProperties) = try .init(self.gpa);
    errdefer out.deinit();
    const res = try self.send(out.arena, scratch.allocator(), .{
        .method = .HEAD,
        .container = name,
        .query = &.{.{ .name = "restype", .value = "container" }},
    });
    out.value = .{
        .etag = try self.etagOf(res.headers),
        .last_modified = dateOf(res.headers, "Last-Modified"),
        .lease_state = headerOf(res.headers, "x-ms-lease-state") orelse "",
        .metadata = try metadataOf(out.arena.allocator(), res.headers),
    };
    return out;
}

// Blobs.

/// Writes the blob in one request, replacing any there unless the
/// conditions say otherwise: `.if_absent` to create only, `.ifMatch(etag)`
/// to replace only the version read. Unmet, `PreconditionFailed`.
///
/// A conditional write whose answer was lost may have landed, and a retry
/// of it then fails its own condition. So a conditional write carries a
/// fresh token in metadata (`azzigwrite`), and on `PreconditionFailed` the
/// client reads the blob's properties: when they hold its token, the write
/// was its own, and it succeeded.
///
/// The bytes are held whole; Put Blob takes up to 5000 MiB.
pub fn putBlob(self: *Client, container: []const u8, name: []const u8, data: []const u8, options: types.PutOptions) Error!types.Written {
    self.engine.begin();
    try self.checkBlob(container, name);
    try self.checkPut(options);
    try self.ensureFlat();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    var headers: std.ArrayList(Header) = .empty;
    try headers.append(a, .{ .name = "x-ms-blob-type", .value = "BlockBlob" });
    try headers.append(a, .{ .name = "x-ms-blob-content-type", .value = options.content_type });
    for (options.metadata) |m| try headers.append(a, .{ .name = try std.fmt.allocPrint(a, "x-ms-meta-{s}", .{m.name}), .value = m.value });
    var token_hex: [32]u8 = undefined;
    const token: ?[]const u8 = if (options.conditions.isNone()) null else t: {
        var bytes: [16]u8 = undefined;
        self.io.random(&bytes);
        token_hex = std.fmt.bytesToHex(bytes, .lower);
        try headers.append(a, .{ .name = "x-ms-meta-" ++ validate.write_token_name, .value = &token_hex });
        break :t &token_hex;
    };
    try appendConditions(a, &headers, options.conditions);
    var crc: [12]u8 = undefined;
    if (options.crc64) {
        crc = core.crc64.toBase64(core.crc64.hash(data));
        try headers.append(a, .{ .name = "x-ms-content-crc64", .value = &crc });
    }

    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const res = self.send(&response, a, .{
        .method = .PUT,
        .container = container,
        .blob = name,
        .headers = headers.items,
        .body = data,
    }) catch |err| switch (err) {
        error.PreconditionFailed => if (token) |t| return self.settle(container, name, t) else return err,
        else => |e| return e,
    };
    return .{ .etag = try self.etagOf(res.headers), .last_modified = dateOf(res.headers, "Last-Modified") };
}

/// After a conditional write refused for its condition: success when the
/// blob holds `token`, which only this call wrote, else the refusal as it
/// was.
fn settle(self: *Client, container: []const u8, name: []const u8, token: []const u8) Error!types.Written {
    var saved: ?core.Diagnostics = null;
    if (self.engine.diagnostics) |d| saved = d.*;
    defer if (saved) |s| {
        self.engine.diagnostics.?.* = s;
    };
    var props = self.properties(container, name, .{}) catch return error.PreconditionFailed;
    defer props.deinit();
    const theirs = props.value.meta(validate.write_token_name) orelse return error.PreconditionFailed;
    if (!std.mem.eql(u8, theirs, token)) return error.PreconditionFailed;
    log.warn("a conditional write to {f}/{f} was refused for its condition but had landed: an earlier attempt's answer was lost", .{ core.logging.escaped(container), core.logging.escaped(name) });
    saved = null;
    if (self.engine.diagnostics) |d| d.clear();
    return .{ .etag = props.value.etag, .last_modified = props.value.last_modified };
}

/// The blob's bytes, all of them or `options.range`, and its properties.
/// `NotFound` when there is none, a conditional read's included;
/// `ContainerNotFound` when its container is not there. A range from 0
/// of an empty blob reads as empty; one past the end is `InvalidRange`.
/// The bytes are buffered, up to the transport's response limit (32 MiB
/// by default).
pub fn getBlob(self: *Client, container: []const u8, name: []const u8, options: types.GetOptions) Error!Owned(types.Blob) {
    self.engine.begin();
    try self.checkBlob(container, name);
    try checkRange(self, options.range);
    try self.ensureFlat();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var headers: std.ArrayList(Header) = .empty;
    if (options.range) |r| try headers.append(a, .{ .name = "x-ms-range", .value = try rangeValue(a, r) });
    try appendConditions(a, &headers, options.conditions);

    var out: Owned(types.Blob) = try .init(self.gpa);
    errdefer out.deinit();
    var head: ?transport.StreamRequest.Head = null;
    const res = self.send(out.arena, a, .{
        .method = .GET,
        .container = container,
        .blob = name,
        .headers = headers.items,
        .head_out = &head,
    }) catch |err| switch (err) {
        error.InvalidRange => if (emptyBlob(options.range, head)) {
            const empty = try self.emptyRead(container, name, options.conditions);
            out.deinit();
            return empty;
        } else return err,
        else => |e| return e,
    };
    out.value = .{ .data = res.body, .properties = try self.propertiesOf(out.arena.allocator(), res.headers) };
    return out;
}

/// Whether a refused ranged read was of an empty blob from its start:
/// production answers that 416, `Content-Range: bytes */0`.
fn emptyBlob(range: ?types.Range, head: ?transport.StreamRequest.Head) bool {
    const r = range orelse return false;
    const h = head orelse return false;
    const content_range = h.header("Content-Range") orelse return false;
    return r.offset == 0 and std.mem.eql(u8, content_range, "bytes */0");
}

fn emptyRead(self: *Client, container: []const u8, name: []const u8, conditions: types.Conditions) Error!Owned(types.Blob) {
    var props = try self.properties(container, name, conditions);
    errdefer props.deinit();
    const out: Owned(types.Blob) = .{ .arena = props.arena, .value = .{ .data = "", .properties = props.value } };
    return out;
}

/// The blob's properties and metadata; `NotFound` when there is none.
pub fn getBlobProperties(self: *Client, container: []const u8, name: []const u8, conditions: types.Conditions) Error!Owned(types.BlobProperties) {
    self.engine.begin();
    try self.checkBlob(container, name);
    try self.ensureFlat();
    return self.properties(container, name, conditions);
}

fn properties(self: *Client, container: []const u8, name: []const u8, conditions: types.Conditions) Error!Owned(types.BlobProperties) {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var headers: std.ArrayList(Header) = .empty;
    try appendConditions(a, &headers, conditions);
    var out: Owned(types.BlobProperties) = try .init(self.gpa);
    errdefer out.deinit();
    const res = try self.send(out.arena, a, .{
        .method = .HEAD,
        .container = container,
        .blob = name,
        .headers = headers.items,
    });
    out.value = try self.propertiesOf(out.arena.allocator(), res.headers);
    return out;
}

/// Deletes the blob and its snapshots: true when there was one, false when
/// there was none, so a delete is safe to repeat. `ContainerNotFound` when
/// the container is not there.
pub fn deleteBlob(self: *Client, container: []const u8, name: []const u8, options: types.DeleteOptions) Error!bool {
    self.engine.begin();
    try self.checkBlob(container, name);
    if (!options.conditions.validForWrite()) return self.invalid("a write takes one condition, or if_match with if_unmodified_since, or if_none_match with if_modified_since", .{});
    try self.ensureFlat();
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var headers: std.ArrayList(Header) = .empty;
    try headers.append(a, .{ .name = "x-ms-delete-snapshots", .value = "include" });
    try appendConditions(a, &headers, options.conditions);
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    _ = self.send(&response, a, .{
        .method = .DELETE,
        .container = container,
        .blob = name,
        .headers = headers.items,
    }) catch |err| switch (err) {
        error.NotFound => return false,
        else => |e| return e,
    };
    return true;
}

/// The blobs under `options.prefix`, in name order, every page read.
/// With `after`, only names past it; with a delimiter, the prefixes that
/// group the rest.
pub fn listBlobs(self: *Client, container: []const u8, options: types.ListOptions) Error!Owned(types.Listing) {
    self.engine.begin();
    try self.checkContainer(container);
    try self.checkList(options);
    try self.ensureFlat();
    var out: Owned(types.Listing) = try .init(self.gpa);
    errdefer out.deinit();
    const a = out.arena.allocator();
    var blobs: std.ArrayList(types.ListedBlob) = .empty;
    var prefixes: std.ArrayList([]const u8) = .empty;
    var marker: []const u8 = "";
    var pages: usize = 0;
    while (true) : (pages += 1) {
        if (pages == max_pages) return self.badAnswer("a listing ran past {d} pages", .{max_pages});
        marker = try self.listPage(container, options, marker, a, &blobs, &prefixes);
        if (marker.len == 0) break;
    }
    out.value = .{ .blobs = try blobs.toOwnedSlice(a), .prefixes = try prefixes.toOwnedSlice(a) };
    return out;
}

/// One page, its entries past `options.after` appended; the next marker,
/// empty after the last page. A page may be short or empty and still name
/// a next one.
fn listPage(
    self: *Client,
    container: []const u8,
    options: types.ListOptions,
    marker: []const u8,
    out: Allocator,
    blobs: *std.ArrayList(types.ListedBlob),
    prefixes: *std.ArrayList([]const u8),
) Error![]const u8 {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const res = try self.send(&response, a, .{ .method = .GET, .container = container, .query = try listQuery(a, options, marker) });
    const root = xml.parse(a, res.body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidResponse => return self.badAnswer("a listing is not XML", .{}),
    };
    if (!std.mem.eql(u8, root.name, "EnumerationResults")) return self.badAnswer("a listing's root is {s}, not EnumerationResults", .{root.name});
    if (root.child("Blobs")) |entries| for (entries.children) |entry| {
        if (std.mem.eql(u8, entry.name, "Blob")) {
            const blob = try self.listedBlob(out, entry);
            if (types.isAfter(blob.name, options.after)) try blobs.append(out, blob);
        } else if (std.mem.eql(u8, entry.name, "BlobPrefix")) {
            const p = try self.nameOf(out, entry);
            if (prefixAfter(p, options.after)) try prefixes.append(out, p);
        }
    };
    return out.dupe(u8, root.childText("NextMarker") orelse "");
}

/// A page's query: what to list, from where, and how much.
fn listQuery(a: Allocator, options: types.ListOptions, marker: []const u8) Allocator.Error![]const shared_key.Param {
    var query: std.ArrayList(shared_key.Param) = .empty;
    try query.appendSlice(a, &.{ .{ .name = "restype", .value = "container" }, .{ .name = "comp", .value = "list" } });
    if (options.prefix.len > 0) try query.append(a, .{ .name = "prefix", .value = options.prefix });
    if (options.delimiter) |d| try query.append(a, .{ .name = "delimiter", .value = d });
    if (options.after) |after| if (after.len > 0) try query.append(a, .{ .name = "startFrom", .value = after });
    if (marker.len > 0) try query.append(a, .{ .name = "marker", .value = marker });
    if (options.page_size) |n| try query.append(a, .{ .name = "maxresults", .value = try std.fmt.allocPrint(a, "{d}", .{n}) });
    if (options.include_metadata) try query.append(a, .{ .name = "include", .value = "metadata" });
    return query.items;
}

/// Whether a prefix may hold names past `after`: it sorts after it, or
/// `after` lies within it.
fn prefixAfter(prefix: []const u8, after: ?[]const u8) bool {
    const bound = after orelse return true;
    return std.mem.order(u8, prefix, bound) == .gt or std.mem.startsWith(u8, bound, prefix);
}

fn listedBlob(self: *Client, out: Allocator, entry: xml.Element) Error!types.ListedBlob {
    const name = try self.nameOf(out, entry);
    const props = entry.child("Properties") orelse return self.badAnswer("a listed blob has no Properties", .{});
    if (props.childText("ResourceType")) |kind| if (std.mem.eql(u8, kind, "directory")) {
        self.namespace = .hierarchical;
        return self.hierarchical();
    };
    const etag = Etag.parse(props.childText("Etag") orelse "") orelse return self.badAnswer("a listed blob's Etag is missing or malformed", .{});
    const size = std.fmt.parseInt(u64, props.childText("Content-Length") orelse "", 10) catch return self.badAnswer("a listed blob's Content-Length is not a number", .{});
    var metadata: std.ArrayList(types.Metadata) = .empty;
    if (entry.child("Metadata")) |m| for (m.children) |c| {
        try metadata.append(out, .{ .name = try out.dupe(u8, c.name), .value = try out.dupe(u8, c.text) });
    };
    return .{
        .name = name,
        .etag = etag,
        .size = size,
        .content_type = try out.dupe(u8, props.childText("Content-Type") orelse ""),
        .last_modified = if (props.childText("Last-Modified")) |t| core.http_date.unixSeconds(t) else null,
        .metadata = try metadata.toOwnedSlice(out),
    };
}

/// An entry's name, percent-decoded when the listing says it is encoded,
/// as it does for a name XML cannot hold.
fn nameOf(self: *Client, out: Allocator, entry: xml.Element) Error![]const u8 {
    const element = entry.child("Name") orelse return self.badAnswer("a listing entry has no Name", .{});
    if (element.attribute("Encoded")) |e| if (std.mem.eql(u8, e, "true")) {
        return (try validate.percentDecode(out, element.text)) orelse return self.badAnswer("an encoded name is not percent-encoding", .{});
    };
    return out.dupe(u8, element.text);
}

// Requests.

const Request = struct {
    method: transport.Method,
    /// Null: the account itself.
    container: ?[]const u8 = null,
    blob: ?[]const u8 = null,
    query: []const shared_key.Param = &.{},
    /// The call's own: conditions, metadata, the blob type, a range.
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    head_out: ?*?transport.StreamRequest.Head = null,
};

/// Sends `req` with the headers every call carries, signed with Shared Key
/// when that is the credential; the answer lives in `response`.
fn send(self: *Client, response: *std.heap.ArenaAllocator, scratch: Allocator, req: Request) Error!transport.StreamResponse {
    var target: Writer.Allocating = .init(scratch);
    writeTarget(&target.writer, self.path_prefix, req) catch return error.OutOfMemory;
    const full = target.written();
    const path = full[0 .. std.mem.indexOfScalar(u8, full, '?') orelse full.len];

    var date_buf: [core.http_date.len]u8 = undefined;
    const date = core.http_date.format(&date_buf, std.Io.Clock.real.now(self.io));
    const request_id = core.arm.clientRequestId(self.io);
    var headers: std.ArrayList(Header) = .empty;
    try headers.appendSlice(scratch, req.headers);
    try headers.appendSlice(scratch, &.{
        .{ .name = "x-ms-version", .value = version },
        .{ .name = "x-ms-date", .value = date },
        .{ .name = "x-ms-client-request-id", .value = &request_id },
    });
    if (self.key) |*key| try headers.append(scratch, .{ .name = "Authorization", .value = try shared_key.authorization(scratch, self.account, key, .{
        .method = req.method,
        .path = path,
        .query = req.query,
        .headers = headers.items,
        .content_length = if (req.body) |b| b.len else 0,
    }) });

    const segments = [_][]const u8{req.body orelse ""};
    return self.engine.executeStream(response, .{
        .method = req.method,
        .path = full,
        .headers = headers.items,
        .body = if (req.body != null) .{ .segments = &segments } else .none,
        .head_out = req.head_out,
        .retry_window_ms = if (self.key != null) signed_retry_window_ms else null,
    }) catch |err| switch (err) {
        // Only a writer sink writes, and every call here buffers.
        error.WriteFailed => unreachable,
        else => |e| e,
    };
}

/// The request's path and query: the prefix, the container, the blob's
/// name percent-encoded, then each parameter, its value strictly encoded.
fn writeTarget(w: *Writer, prefix: []const u8, req: Request) Writer.Error!void {
    try w.print("{s}/", .{prefix});
    if (req.container) |c| {
        try w.writeAll(c);
        if (req.blob) |b| {
            try w.writeByte('/');
            try validate.writeBlobPath(w, b);
        }
    }
    for (req.query, 0..) |p, i| {
        try w.writeByte(if (i == 0) '?' else '&');
        try core.query.writeValue(w, p.name);
        try w.writeByte('=');
        try core.query.writeValue(w, p.value);
    }
}

/// The condition headers, ETags quoted and times as HTTP dates.
fn appendConditions(a: Allocator, headers: *std.ArrayList(Header), c: types.Conditions) Allocator.Error!void {
    if (c.if_match) |e| try headers.append(a, .{ .name = "If-Match", .value = try quote(a, e) });
    if (c.if_none_match) |m| try headers.append(a, .{ .name = "If-None-Match", .value = switch (m) {
        .any => "*",
        .etag => |e| try quote(a, e),
    } });
    if (c.if_modified_since) |s| try headers.append(a, .{ .name = "If-Modified-Since", .value = try httpDate(a, s) });
    if (c.if_unmodified_since) |s| try headers.append(a, .{ .name = "If-Unmodified-Since", .value = try httpDate(a, s) });
}

fn quote(a: Allocator, e: Etag) Allocator.Error![]const u8 {
    var buf: [Etag.max_len + 2]u8 = undefined;
    return a.dupe(u8, e.quoted(&buf));
}

fn httpDate(a: Allocator, seconds: i64) Allocator.Error![]const u8 {
    var buf: [core.http_date.len]u8 = undefined;
    return a.dupe(u8, core.http_date.format(&buf, .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s }));
}

fn rangeValue(a: Allocator, r: types.Range) Allocator.Error![]const u8 {
    if (r.length) |n| return std.fmt.allocPrint(a, "bytes={d}-{d}", .{ r.offset, r.offset + n - 1 });
    return std.fmt.allocPrint(a, "bytes={d}-", .{r.offset});
}

// The account's namespace.

/// Reads the account's properties on the first call, and refuses an
/// account with a hierarchical namespace. A principal whose data role
/// lacks the right to read them is answered 403: the namespace is then
/// unknown, and a listing that holds a directory refuses instead.
fn ensureFlat(self: *Client) Error!void {
    if (!self.check_namespace) return;
    switch (self.namespace) {
        .flat, .unknown => return,
        .hierarchical => return self.hierarchical(),
        .unchecked => {},
    }
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    var response: std.heap.ArenaAllocator = .init(self.gpa);
    defer response.deinit();
    const res = self.send(&response, scratch.allocator(), .{
        .method = .HEAD,
        .query = &.{ .{ .name = "restype", .value = "account" }, .{ .name = "comp", .value = "properties" } },
    }) catch |err| switch (err) {
        error.PermissionDenied => {
            log.debug("the account's properties are not readable with this credential; its namespace is unknown", .{});
            self.namespace = .unknown;
            self.engine.begin();
            return;
        },
        else => |e| return e,
    };
    const hns = headerOf(res.headers, "x-ms-is-hns-enabled") orelse "false";
    self.namespace = if (std.ascii.eqlIgnoreCase(hns, "true")) .hierarchical else .flat;
    if (self.namespace == .hierarchical) return self.hierarchical();
}

fn hierarchical(self: *Client) error{HierarchicalNamespace} {
    if (self.engine.diagnostics) |d| d.print("the account has a hierarchical namespace (ADLS Gen2), which this client refuses: its listings hold directories, and a delete leaves them", .{});
    return error.HierarchicalNamespace;
}

// Answers.

fn headerOf(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}

fn dateOf(headers: []const Header, name: []const u8) ?i64 {
    return core.http_date.unixSeconds(headerOf(headers, name) orelse return null);
}

fn etagOf(self: *Client, headers: []const Header) Error!Etag {
    return Etag.parse(headerOf(headers, "ETag") orelse "") orelse return self.badAnswer("the answer's ETag is missing or malformed", .{});
}

/// Every `x-ms-meta-*` header, its name past the prefix.
fn metadataOf(a: Allocator, headers: []const Header) Allocator.Error![]const types.Metadata {
    var out: std.ArrayList(types.Metadata) = .empty;
    for (headers) |h| if (std.ascii.startsWithIgnoreCase(h.name, "x-ms-meta-")) {
        try out.append(a, .{ .name = try std.ascii.allocLowerString(a, h.name["x-ms-meta-".len..]), .value = try a.dupe(u8, h.value) });
    };
    return out.toOwnedSlice(a);
}

/// A blob's properties from its headers. A ranged read's size is the
/// whole blob's, from `Content-Range`.
fn propertiesOf(self: *Client, a: Allocator, headers: []const Header) Error!types.BlobProperties {
    const size = if (headerOf(headers, "Content-Range")) |cr|
        totalOf(cr) orelse return self.badAnswer("the answer's Content-Range is malformed", .{})
    else
        std.fmt.parseInt(u64, headerOf(headers, "Content-Length") orelse "", 10) catch return self.badAnswer("the answer's Content-Length is not a number", .{});
    return .{
        .etag = try self.etagOf(headers),
        .size = size,
        .content_type = try a.dupe(u8, headerOf(headers, "Content-Type") orelse ""),
        .last_modified = dateOf(headers, "Last-Modified"),
        .created = dateOf(headers, "x-ms-creation-time"),
        .content_md5 = try a.dupe(u8, headerOf(headers, "x-ms-blob-content-md5") orelse headerOf(headers, "Content-MD5") orelse ""),
        .blob_type = .parse(headerOf(headers, "x-ms-blob-type") orelse "BlockBlob"),
        .metadata = try metadataOf(a, headers),
    };
}

/// The total from `bytes a-b/total`.
fn totalOf(content_range: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, content_range, "bytes ")) return null;
    const slash = std.mem.lastIndexOfScalar(u8, content_range, '/') orelse return null;
    return std.fmt.parseInt(u64, content_range[slash + 1 ..], 10) catch null;
}

// Checks before sending.

fn checkContainer(self: *Client, name: []const u8) Error!void {
    if (!validate.isContainerName(name)) return self.invalid("a container name is 3 to 63 lowercase letters, digits and single hyphens, beginning and ending with a letter or digit: {s}", .{name});
}

fn checkBlob(self: *Client, container: []const u8, name: []const u8) Error!void {
    try self.checkContainer(container);
    if (validate.blobNameProblem(name)) |why| return self.invalid("{s}", .{why});
}

fn checkPut(self: *Client, options: types.PutOptions) Error!void {
    if (!validate.isContentType(options.content_type)) return self.invalid("a content type is visible ASCII and single spaces, 1 to 256 characters", .{});
    if (!options.conditions.validForWrite()) return self.invalid("a write takes one condition, or if_match with if_unmodified_since, or if_none_match with if_modified_since", .{});
    var names: [64][]const u8 = undefined;
    var values: [64][]const u8 = undefined;
    if (options.metadata.len > names.len) return self.invalid("a blob takes at most {d} metadata entries here", .{names.len});
    for (options.metadata, 0..) |m, i| {
        names[i] = m.name;
        values[i] = m.value;
    }
    if (validate.metadataSetProblem(names[0..options.metadata.len], values[0..options.metadata.len])) |why| return self.invalid("{s}", .{why});
}

fn checkRange(self: *Client, range: ?types.Range) Error!void {
    const r = range orelse return;
    const n = r.length orelse return;
    if (n == 0) return self.invalid("a range's length is at least 1", .{});
    _ = std.math.add(u64, r.offset, n - 1) catch return self.invalid("a range ends within 2^64 bytes", .{});
}

fn checkList(self: *Client, options: types.ListOptions) Error!void {
    if (options.page_size) |n| if (n == 0 or n > 5000) return self.invalid("a listing's page size is 1 to 5000", .{});
    if (options.delimiter) |d| if (d.len == 0) return self.invalid("a delimiter is not empty", .{});
    for ([_][]const u8{ options.prefix, options.after orelse "", options.delimiter orelse "" }) |text| {
        for (text) |c| if (c < 0x20 or c == 0x7f) return self.invalid("a prefix, delimiter or after holds no control characters", .{});
    }
}

fn invalid(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidArgument} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidArgument;
}

fn badAnswer(self: *Client, comptime fmt: []const u8, args: anytype) error{InvalidResponse} {
    if (self.engine.diagnostics) |d| d.print(fmt, args);
    return error.InvalidResponse;
}

test {
    std.testing.refAllDecls(@This());
}

test "account names and base URLs" {
    const testing = std.testing;
    for ([_][]const u8{ "abc", "azzigexample1", "devstoreaccount1", "a1b2c3d4e5f6g7h8i9j0k1l2" }) |ok| try testing.expect(isAccountName(ok));
    for ([_][]const u8{ "ab", "Abc", "a-b", "a_b", "a1b2c3d4e5f6g7h8i9j0k1l2m" }) |bad| try testing.expect(!isAccountName(bad));
    for ([_][]const u8{ "https://a.blob.core.windows.net", "http://127.0.0.1:10000" }) |ok| try testing.expect(isBaseUrl(ok));
    for ([_][]const u8{ "", "ftp://a", "https://", "https://a/", "https://a/x", "https://u@a", "https://a?x", "http://a b" }) |bad| try testing.expect(!isBaseUrl(bad));
    try testing.expectEqual(@as(?u64, 3), totalOf("bytes 0-0/3"));
    try testing.expectEqual(@as(?u64, 0), totalOf("bytes */0"));
    try testing.expectEqual(@as(?u64, null), totalOf("0-0/3"));
}
