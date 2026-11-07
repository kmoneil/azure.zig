[Docs](../README.md) › Resources

# resources: subscriptions, resource groups and providers

The Azure Resource Manager basics a program needs before anything else:
the subscriptions its credential can see, resource groups to hold what it
makes, and whether a subscription has registered the resource providers
it will use.

Measured against Azure on 2026-11-07, in eastus2; the live suite
(`tests/resources_azure_integration.zig`) runs it again.

## A first program

<!-- snippet: examples/resources_subscriptions.zig -->
```zig
const std = @import("std");
const resources = @import("resources");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // A token from tools/azure-token.sh, or from the Azure CLI:
    // az account get-access-token --query accessToken -o tsv
    const text = init.environ_map.get("AZURE_TOKEN") orelse {
        std.debug.print("set AZURE_TOKEN to a Resource Manager token\n", .{});
        return;
    };
    var token: resources.StaticToken = .{ .token = std.mem.trim(u8, text, &std.ascii.whitespace) };
    var diag: resources.Diagnostics = .{};
    var client: resources.Client = try .init(gpa, init.io, .{
        .token_provider = token.provider(),
        .diagnostics = &diag,
    });
    defer client.deinit();

    var subs = client.listSubscriptions() catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer subs.deinit();
    for (subs.value) |s| std.debug.print("{s}  {s}  {t}\n", .{ s.id, s.display_name, s.state });
}
```

## The calls

| Call | Does |
| --- | --- |
| `listSubscriptions()` | Every subscription the credential can see, every page read |
| `createResourceGroup(sub, name, spec)` | Makes the group (201, `created` true), or finds it there and gives it the spec's tags (200) |
| `getResourceGroup(sub, name)` | One group; `NotFound` when there is none |
| `listResourceGroups(sub, filter)` | The subscription's groups, every page; with a `TagFilter`, those with that tag |
| `beginDeleteResourceGroup(sub, name, options)` | Begins deleting the group and all in it; returns the `Operation` |
| `waitOperation(&op, timeout_ms)` | Polls until the operation ends or the time passes, leaving it as it stands |
| `getProvider(sub, namespace)` | Whether the subscription has registered a provider, such as `Microsoft.Compute` |
| `registerProvider(sub, namespace)` | Registers it; the answer is usually `registering` |

Every result is an `Owned(T)`: one `deinit` frees it.

## Resource groups

`createResourceGroup` is one PUT, and safe to repeat. A group found there
already keeps its location, and its tags become exactly the spec's: the
tags are always sent, an empty set included. A group being deleted, or
one already in another location, is `Conflict`; `Diagnostics.code()` says
which (`ResourceGroupBeingDeleted`, `InvalidResourceGroupLocation`).

A delete is a long-running operation: ARM answers 202 and a URL to poll,
and the group reads `Deleting` until it is gone. `waitOperation` waits what
each answer asks (`Retry-After`, at least a second) and stops at its time
limit with the operation as it stands, so a caller can wait in steps.
`DeleteOptions.force_vms` deletes the group's VMs and scale sets without
shutting them down first, as a spot worker's group wants.

Names are checked before anything is sent: a subscription is a GUID, a
group's name is 1 to 90 of letters, digits and `-_.()`, not ending in `.`
(ARM also takes letters outside ASCII; this client does not), and tag
names hold none of `<>%&\?/`. `limits` has the rules.

## Listing by tag

<!-- snippet: tests/docs_examples.zig#list-by-tag -->
```zig
var mine = try client.listResourceGroups(sub, .{ .name = "azzig-run", .value = run });
defer mine.deinit();
```

The filter goes to ARM as OData (`tagName eq '...' and tagValue eq '...'`,
a quote in either doubled), so only matching groups come back. Tag names
match without regard to case, as ARM's do; `ResourceGroup.tag(name)` reads
one the same way.

## Providers

A subscription must register a resource provider before using it, and
only a principal with rights at subscription scope can. An unregistered
one makes a write fail with `ProviderNotRegistered`, whichever of ARM's
four spellings the answer used. Nothing here registers on its own: register
the providers a program needs once, as an administrator, or call
`registerProvider` and poll `getProvider` where the credential may.

## Errors

`Error` is closed: core's ARM refusals by status (`NotFound`, `Conflict`,
`PermissionDenied`, `Throttled`, `ServerError` and the rest), the
transport's and the token provider's failures, `InvalidArgument` for what
was refused before sending, `InvalidResponse` for an answer that is not
ARM's JSON, and `InvalidOperation` for a delete that cannot be followed.
After a failure, `Diagnostics` has the status, ARM's code and message, and
the provider's `x-ms-request-id`. Calls are retried on 408, 429 and 5xx
with backoff, waiting what ARM asks up to a minute; past that the call
returns `Throttled` at once, the delay in `Diagnostics.retry_after_ms`.

## Testing code that uses this module

`testing.FakeResources` is Resource Manager in memory, behind
`Options.transport`: subscriptions, groups and providers a test adds,
lists paged (`page_size`), filters by tag, and a delete that answers 202
for `delete_polls` polls before the group is gone. Give the client
`testing.FakeClock`'s `io` and the polls take no time.

<!-- snippet: tests/docs_examples.zig#fake-resources -->
```zig
var fake: resources.testing.FakeResources = .init(gpa);
defer fake.deinit();
try fake.addSubscription("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f", "test");
var clock: resources.testing.FakeClock = .{};
var token: resources.StaticToken = .{ .token = "t" };
var client: resources.Client = try .init(gpa, clock.io(), .{
    .token_provider = token.provider(),
    .transport = fake.transport(),
});
defer client.deinit();
```
