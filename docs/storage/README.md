[Docs](../README.md) › Storage

# storage: Blob Storage

Containers, and block blobs written in one request, read whole or in
part, listed and deleted, under ETag conditions, on Blob Storage's REST
API at x-ms-version 2026-04-06. A call is authorized with an Entra token
or with Shared Key. `testing.FakeBlob` is Blob Storage in memory, for
your own tests.

Measured against production and Azurite 3.37.0 on 2026-11-07. The suites
(`tests/storage_azure_integration.zig` and
`tests/storage_azurite_integration.zig`) run it again, and print as a
`fact:` what each service answered.

## A first program

It copies a file to a blob or a blob to a file. With `AZURITE=1` it uses
Azurite on 127.0.0.1:10000; otherwise it needs the account's name in
`AZURE_STORAGE_ACCOUNT`, and the account's key in `AZURE_STORAGE_KEY` or
an Entra token in `AZURE_STORAGE_TOKEN`.

<!-- snippet: examples/blob_cp.zig -->
```zig
const std = @import("std");
const storage = @import("storage");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // blob_cp put <file> <container>/<blob>, or get <container>/<blob> <file>
    const put = args.len == 4 and std.mem.eql(u8, args[1], "put");
    const get = args.len == 4 and std.mem.eql(u8, args[1], "get");
    const remote = if (put) args[3] else if (get) args[2] else "";
    const slash = std.mem.indexOfScalar(u8, remote, '/') orelse {
        std.debug.print("blob_cp put <file> <container>/<blob>, or get <container>/<blob> <file>\n", .{});
        return;
    };
    const container, const blob, const local = .{ remote[0..slash], remote[slash + 1 ..], if (put) args[2] else args[3] };

    // Azurite with AZURITE=1; else AZURE_STORAGE_ACCOUNT, with its key in
    // AZURE_STORAGE_KEY or an Entra token in AZURE_STORAGE_TOKEN.
    var token: storage.StaticToken = .{ .token = env.get("AZURE_STORAGE_TOKEN") orelse "" };
    const endpoint: storage.Endpoint = if (env.get("AZURITE") != null)
        .{ .azurite = .{} }
    else
        .{ .account = .{ .name = env.get("AZURE_STORAGE_ACCOUNT") orelse "" } };
    const credential: storage.Credential = if (env.get("AZURITE") != null)
        .{ .shared_key = storage.azurite_key }
    else if (env.get("AZURE_STORAGE_KEY")) |key|
        .{ .shared_key = key }
    else
        .{ .token = token.provider() };

    var diag: storage.Diagnostics = .{};
    var client = storage.Client.init(init.gpa, init.io, .{ .endpoint = endpoint, .credential = credential, .diagnostics = &diag }) catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer client.deinit();

    if (put) {
        const data = try std.Io.Dir.cwd().readFileAlloc(init.io, local, init.gpa, .limited(256 << 20));
        defer init.gpa.free(data);
        const written = client.putBlob(container, blob, data, .{}) catch |err| {
            std.debug.print("{t}: {f}\n", .{ err, diag });
            return err;
        };
        std.debug.print("{s} -> {s}: {d} bytes, ETag {f}\n", .{ local, remote, data.len, written.etag });
    } else {
        var got = client.getBlob(container, blob, .{}) catch |err| {
            std.debug.print("{t}: {f}\n", .{ err, diag });
            return err;
        };
        defer got.deinit();
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = local, .data = got.value.data });
        std.debug.print("{s} -> {s}: {d} bytes, ETag {f}\n", .{ remote, local, got.value.data.len, got.value.properties.etag });
    }
}
```

## The calls

| Call | Does |
| --- | --- |
| `createContainer(name)` | Makes a container: true, or false when it was there |
| `deleteContainer(name)` | Deletes a container and its blobs: true, or false when there was none |
| `getContainerProperties(name)` | Its ETag, lease state and metadata; `ContainerNotFound` when there is none |
| `putBlob(container, name, data, options)` | Writes a blob in one request, under `options.conditions`, with a content type and metadata |
| `getBlob(container, name, options)` | Its bytes, all of them or `options.range`, and its properties |
| `getBlobProperties(container, name, conditions)` | Its size, ETag, content type, dates, MD5 and metadata, without the bytes |
| `deleteBlob(container, name, options)` | Deletes a blob and its snapshots: true, or false when there was none |
| `listBlobs(container, options)` | The blobs under a prefix in name order, every page read, after a name or grouped by a delimiter |

A result that holds what the answer said is an `Owned(T)`: one `deinit`
frees it. `putBlob` gives back a `Written`, its ETag and Last-Modified,
by value.

## Several tasks

A client takes one call at a time. For calls from several tasks at once,
give each task a client of its own: `client.sibling(&diag)` makes one on
the same account, endpoint and credential, reporting into its own
`Diagnostics`. A sibling has a connection of its own when the transport
is the built-in one; a custom `Options.transport` is shared, and must take
calls from several tasks at once, as the token provider is shared. The
account's namespace is read once for a client and all its siblings, by
whichever asks first while the rest wait, so a pool of 32 makes one such
request, not 32. Each is freed with its own `deinit`, in any order.

## Accounts and credentials

`Endpoint` names the account: `.account` with its name and cloud
(`https://{name}.blob.core.windows.net` in the public cloud), `.azurite`,
or `.custom` with any URL, path style or not. An account name is 3 to 24
lowercase letters and digits.

`Credential` is one of two. `.token` takes a `TokenProvider` for
`https://storage.azure.com/.default`, the same scope in every cloud, and
the principal needs a data role where the blobs are: Storage Blob Data
Contributor to read, write, list and delete. `.shared_key` takes the
account's key as the portal and ARM's `listKeys` give it; the account
must allow Shared Key. The key is held decoded, and zeroed by `deinit`.

A Shared Key signature is good for 15 minutes after the `x-ms-date` it
covers, so the client signs each attempt afresh, with a date of its own,
through rest-core's per-attempt signer: a retry however late carries a
good signature. Retries are azcore's, four attempts on 408, 429, 500,
502, 503 and 504, waiting what the service asks up to a minute.

## Versions and conditions

An `Etag` is a version: opaque, good only for `eql`. Headers send it
quoted and listings bare; the client holds it bare and quotes it to
send. Production's are `0x` and 15 hex digits, which nothing promises,
so nothing here reads them as numbers.

<!-- snippet: tests/docs_examples.zig#compare-and-swap -->
```zig
// Create only: PreconditionFailed when the blob is there already.
const first = try client.putBlob("bucket", "jobs/latest", "1", .{ .conditions = .if_absent });
// Replace only the version read: compare and swap.
var read = try client.getBlob("bucket", "jobs/latest", .{});
defer read.deinit();
_ = try client.putBlob("bucket", "jobs/latest", "2", .{ .conditions = .ifMatch(read.value.properties.etag) });
// That version is gone now, so a swap from it is refused.
const stale = client.putBlob("bucket", "jobs/latest", "3", .{ .conditions = .ifMatch(first.etag) });
```

`Conditions` has four fields: `if_match`, `if_none_match` (an ETag, or
`.any`), `if_modified_since` and `if_unmodified_since` (Unix seconds). A
read takes any of them. A write takes one, or `if_match` with
`if_unmodified_since`, or `if_none_match` with `if_modified_since`, as
Blob Storage allows; any other set is refused before it is sent.

An unmet condition on a write is `PreconditionFailed`. Production
answers create only over a blob 409 `BlobAlreadyExists`, and the rest
412 `ConditionNotMet`; both are `PreconditionFailed`, with the code in
`Diagnostics`. On a read, an unmet `if_match` or `if_unmodified_since`
is `PreconditionFailed`, and an unmet `if_none_match` or
`if_modified_since` is `NotModified` (304). A conditional read of a blob
that is not there is `NotFound`, as production answers it with 404;
Azurite answers it 412.

A conditional write whose answer was lost may have landed, and its retry
then fails its own condition. So a conditional write carries a fresh
random token in metadata, `azzigwrite`, and on `PreconditionFailed` the
client reads the blob's properties: when they hold its token, the write
was its own, and it succeeded with the ETag they give. The token stays
on the blob; metadata named `azzigwrite` is the client's own.

## Reading

`getBlob` reads the whole blob, or `options.range`: `length` bytes from
`offset`, or to the end. A ranged read's `properties.size` is the whole
blob's. The bytes are buffered, up to the transport's response limit,
32 MiB unless a transport of your own says otherwise; streaming larger
blobs comes with large transfers.

A range from 0 of an empty blob reads as empty, though production
answers it 416 `InvalidRange` (`Content-Range: bytes */0`) and the
client then reads the blob's properties. A range from the end of a
blob, or past it, is `InvalidRange`; Azurite answers a range from the
end with no bytes instead.

## Listing

<!-- snippet: tests/docs_examples.zig#list-after -->
```zig
for ([_][]const u8{ "events/000001", "events/000002", "events/000003" }) |name| {
    _ = try client.putBlob("bucket", name, "e", .{});
}
// The names under events/ that sort after the last one read.
var newer = try client.listBlobs("bucket", .{ .prefix = "events/", .after = "events/000001" });
defer newer.deinit();
// newer.value.blobs: events/000002 and events/000003, each with its
// name, ETag, size and content type.
```

`listBlobs` reads every page until the service names no next one; a page
may be short, or empty, and still name another. `after` keeps only names
that sort after it in byte order: it is sent as `startFrom`, which
includes the name itself and which an older service or emulator may
ignore, and the client filters as well. With a `delimiter`, names past
the prefix that hold it are grouped into `Listing.prefixes`, each kept
when it may hold names past `after`. `include_metadata` reads each
blob's metadata too, and `page_size` asks for 1 to 5000 a page. Keep
names ASCII where their order matters: the service orders the rest by
rules the documentation leaves open.

A name XML cannot hold comes back percent-encoded (`Encoded="true"`),
and the client decodes it.

## Deleting

`deleteBlob` deletes the blob with its snapshots, and a blob not there
is false, so a delete is safe to repeat; it takes conditions as a write
does. `deleteContainer` deletes everything in the container. A container
just deleted may go on answering for 30 seconds or more, so a second
delete can say true, and its name can be made again only after that.

## Names and checks

Names are checked before anything is sent. A container's is 3 to 63
lowercase letters, digits and single hyphens, beginning and ending with
a letter or digit. A blob's is 1 to 1024 characters of UTF-8 with no
control characters, and the client also refuses what the service or a
proxy on the way would change: a `\`, a `.` or `..` segment, a name or
segment ending in `.`, a leading or trailing `/`. Every byte of a blob's
name but the unreserved ones and `/` goes percent-encoded.

A metadata name is a lowercase letter, then lowercase letters and
digits; a value is printable ASCII with no space at either end and none
doubled; all of it is at most 8 KiB. The service signs headers in an
order of its own, which for these names is byte order, so Shared Key
needs no collation tables. `limits` has the rules.

## Hierarchical namespace

An account with a hierarchical namespace (ADLS Gen2) is refused with
`HierarchicalNamespace`: its listings hold directories, its deletes leave
them, and Azurite cannot emulate it. The first call reads the account's
properties once; a credential that may not read them leaves the
namespace unknown, and a listing that holds a directory refuses then.
`Options.check_hierarchical_namespace = false` skips the read.

## Errors

`Error` is closed. Refusals by status and code: `BadRequest`,
`Unauthenticated`, `PermissionDenied` (a missing data role, a wrong or
stale signature, Shared Key disallowed, a firewall), `NotFound`,
`ContainerNotFound`, `ContainerAlreadyExists`, `Conflict`,
`PreconditionFailed`, `NotModified`, `InvalidRange`, `RequestTimeout`,
`Throttled` (429, and 503 `ServerBusy`), `ServerError`, and
`FeatureNotSupported`, Azurite's answer to what it does not emulate,
never retried. Then the transport's and the token provider's failures,
`InvalidArgument` for what was refused before sending, `InvalidResponse`
for an answer that is not Blob Storage's, and `HierarchicalNamespace`.
After a failure, `Diagnostics` has the status, the code
(`x-ms-error-code`, or the XML body's), the message's first line and the
request id.

## Testing code that uses this module

`testing.FakeBlob` is Blob Storage in memory, behind
`Options.transport`, answering as production answered on 2026-11-07:
every XML body after the byte order mark production sends, create only
over a blob 409, a conditional read of a blob not there 404, a range of
an empty blob 416, opaque markers. `addContainer` and `putDirect` set it
up, `findBlob` reads what it holds, `page_size` and `empty_page_every`
make listings take pages, `fail_next` refuses the next request as asked,
`lose_next_answer` does the next write and loses its answer,
`hierarchical` and `account_info_forbidden` make an account this client
refuses. It checks that a request is authorized and carries the version
and date, not the signature; Azurite and the live suite check that.

<!-- snippet: tests/docs_examples.zig#fake-blob -->
```zig
var fake: storage.testing.FakeBlob = .init(gpa);
defer fake.deinit();
try fake.addContainer("bucket");
var clock: storage.testing.FakeClock = .{};
var client: storage.Client = try .init(gpa, clock.io(), .{
    .endpoint = .{ .custom = .{ .url = storage.testing.FakeBlob.default_url, .account = "azzigfake" } },
    .credential = .{ .shared_key = storage.azurite_key },
    .transport = fake.transport(),
});
defer client.deinit();
```

Large streamed transfers, with CRC-64 on each, come next (m2); SAS,
leases and append blobs after (m3).
