[Docs](../README.md) › Network

# network: virtual networks, subnets and security groups

Enough network for a fleet of spot VMs, on Microsoft.Network at
api-version 2026-03-01: a virtual network, its subnets, private unless
asked otherwise and with service endpoints, and network security groups
with their rules.

Measured against Azure on 2026-11-07, in eastus2. The live suite
(`tests/network_azure_integration.zig`) runs it again, and prints as a
`fact:` each thing `FakeNetwork` assumes: a refusal's status and code, how
an operation is followed, what a delete of nothing answers.

## A first program

It needs a token for Resource Manager, a subscription, and a resource
group of yours, which must exist: `resources.Client.createResourceGroup`
makes one.

<!-- snippet: examples/network_workers.zig -->
```zig
const std = @import("std");
const network = @import("network");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const env = init.environ_map;
    // A token from tools/azure-token.sh, or from the Azure CLI:
    // az account get-access-token --query accessToken -o tsv
    // and a resource group of yours, which must exist.
    const text = env.get("AZURE_TOKEN");
    const sub = env.get("AZURE_SUBSCRIPTION");
    const group = env.get("AZURE_GROUP");
    if (text == null or sub == null or group == null) {
        std.debug.print("set AZURE_TOKEN, AZURE_SUBSCRIPTION and AZURE_GROUP\n", .{});
        return;
    }
    var token: network.StaticToken = .{ .token = std.mem.trim(u8, text.?, &std.ascii.whitespace) };
    var diag: network.Diagnostics = .{};
    var client: network.Client = try .init(gpa, init.io, .{
        .token_provider = token.provider(),
        .diagnostics = &diag,
    });
    defer client.deinit();

    // A network with one private subnet, which reaches Storage in its
    // region over a service endpoint.
    var op = client.beginCreateVirtualNetwork(sub.?, group.?, "workers-vnet", .{
        .location = env.get("AZURE_LOCATION") orelse "eastus2",
        .address_prefixes = &.{"10.20.0.0/16"},
        .subnets = &.{.{ .name = "workers", .spec = .{
            .address_prefix = "10.20.1.0/24",
            .service_endpoints = &.{"Microsoft.Storage"},
        } }},
    }) catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer op.deinit();
    client.waitOperation(&op, 5 * 60 * 1000) catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    if (op.value.state != .succeeded) {
        std.debug.print("{t}: {s}: {s}\n", .{ op.value.state, op.value.failure_code, op.value.failure_message });
        return;
    }

    var subnet = try client.getSubnet(sub.?, group.?, "workers-vnet", "workers");
    defer subnet.deinit();
    // What a VM's network interface names.
    std.debug.print("{s}\n", .{subnet.value.id});
}
```

## The calls

| Call | Does |
| --- | --- |
| `beginCreateVirtualNetwork(sub, group, name, spec)` | Makes the network, or makes one there already exactly the spec, its subnets included |
| `getVirtualNetwork(sub, group, name)` | One network, with its subnets; `NotFound` when there is none |
| `beginDeleteVirtualNetwork(sub, group, name)` | Deletes the network and its subnets |
| `beginCreateSubnet(sub, group, network, name, spec)` | Makes a subnet of a network that is there, or makes one there already exactly the spec |
| `getSubnet(sub, group, network, name)` | One subnet |
| `beginDeleteSubnet(sub, group, network, name)` | Deletes a subnet |
| `beginCreateSecurityGroup(sub, group, name, spec)` | Makes a network security group, or makes one there already exactly the spec, its rules included |
| `getSecurityGroup(sub, group, name)` | One group, with its rules, Azure's default rules, and the subnets it applies to |
| `beginDeleteSecurityGroup(sub, group, name)` | Deletes a group |
| `waitOperation(&op, timeout_ms)` | Polls until the operation ends or the time passes, leaving it as it stands |

Every result is an `Owned(T)`: one `deinit` frees it. `ids` writes the ARM
id of a network, a subnet, a security group or a NAT gateway from its
names, for a spec that names another resource and for a VM's network
interface, before anything is read.

## Every write is long-running

Network answers every create and delete before it is done, with a URL to
poll (`Azure-AsyncOperation`). The `begin` calls send the write and return
the `Operation`; `waitOperation` waits what each answer asks (`Retry-After`,
at least a second) and stops at its time limit with the operation as it
stands, so a caller can wait in steps; the `get` calls read what it made.
While it runs, the resource reads `Updating`, or `Deleting`.

A failed operation is an answer, not an error: `op.value.state` is
`.failed`, with Network's code and message in `failure_code` and
`failure_message`, and the resource reads `Failed`. Make it again with the
same spec, or delete it.

A delete of what is not there has nothing to do: Network answers 204, and
the operation `begin` returns has already succeeded. Deleting is safe to
repeat, but for a subnet of a network that is not there: its path goes
through the network, so that is `NotFound` (404 `ResourceNotFound`,
naming the network).

## Networks and subnets

A create makes the resource exactly its spec, whether it is new or there
already. For a network that includes its subnets: they are always sent, an
empty list included, so once the create ends the network has the spec's
subnets and no others. A subnet made on its own with `beginCreateSubnet`
and left out of a later network create is deleted, and while anything uses
it (a VM's network interface) that create is refused with
`InUseSubnetCannotBeDeleted`. Put a network's subnets in its spec, or
never make the network again once it has some of its own.

`SubnetSpec.default_outbound_access` is always sent, since its default
depends on the api-version, and is false unless set: the subnet is
private. Its VMs still reach Storage in their own region and the instance
metadata service, and so managed identity's tokens, which is all a spot
worker reading and writing blobs needs. Anything else on the internet
(package mirrors, registries, other regions) needs a NAT gateway
(`nat_gateway`, by ARM id), a public IP, or a firewall. A change to it
reaches a running VM only after the VM is stopped and deallocated.

`service_endpoints` keeps the subnet's traffic to a service, such as
`Microsoft.Storage`, on Azure's network, and lets the service's firewall
admit the subnet by name. Azure says which regions each endpoint reaches,
in `ServiceEndpoint.locations`.

Network refuses, with 400 (`BadRequest`), a subnet whose range lies
outside its network's (`NetcfgSubnetRangeOutsideVnet`) or overlaps
another subnet's (`NetcfgSubnetRangesOverlap`) and a reference to a
resource that is not there (`InvalidResourceReference`); and with 409
(`Conflict`), a resource made again in another location
(`InvalidResourceLocation`). A range with host bits set
(`InvalidCIDRNotation`) the client refuses before sending.

## Security groups

<!-- snippet: tests/docs_examples.zig#security-group -->
```zig
var nsg_op = try client.beginCreateSecurityGroup(sub, "rg", "pb-nsg", .{
    .location = "eastus2",
    .rules = &.{.{
        .name = "AllowSsh",
        .priority = 100,
        .direction = .inbound,
        .access = .allow,
        .protocol = .tcp,
        .source_address_prefixes = &.{"203.0.113.0/24"},
        .destination_port_ranges = &.{"22"},
    }},
});
defer nsg_op.deinit();
try client.waitOperation(&nsg_op, 60_000);

const nsg_id = try network.ids.securityGroup(gpa, sub, "rg", "pb-nsg");
defer gpa.free(nsg_id);
var vnet_op = try client.beginCreateVirtualNetwork(sub, "rg", "pb-vnet", .{
    .location = "eastus2",
    .address_prefixes = &.{"10.20.0.0/16"},
    .subnets = &.{.{ .name = "workers", .spec = .{
        .address_prefix = "10.20.1.0/24",
        .service_endpoints = &.{"Microsoft.Storage"},
        .security_group = nsg_id,
    } }},
});
defer vnet_op.deinit();
try client.waitOperation(&vnet_op, 60_000);
```

Of the rules a packet matches, the one with the lowest priority number
decides. A rule's priority is 100 to 4096 and unique among the group's
rules of its direction; an inbound and an outbound rule may share one.
Below them sit Azure's six default rules (65000 and over), which allow
traffic within the virtual network and from Azure's load balancer, deny
all other inbound traffic, and allow outbound traffic to the network and
the internet: a group with no rules of its own already keeps the internet
out. A create makes the group's rules exactly the spec's.

Addresses and ports are lists, each with one value at least (`*` by
default): an address is `*`, an address or CIDR, or a service tag such as
`Internet`, `VirtualNetwork` or `Storage.EastUS2`, and a port is `*`, one
port, or `low-high`. Network takes one value in a singular field and more
in a plural one, and refuses both at once; the client sends whichever
fits, and reads both back into the list.

A group that applies to a subnet or a network interface cannot be deleted
(`InUseNetworkSecurityGroupCannotBeDeleted`): make the subnet again
without it first, or delete the network.

## Names and checks

Names are checked before anything is sent, since each goes into the
request's path: a virtual network's is 2 to 64, and a subnet's, a security
group's and a rule's 1 to 80, of letters, digits and `.-_`, beginning with
a letter or digit and ending with one or `_`. Ranges are CIDRs with no
host bits set (`10.20.1.0/24`, not `10.20.1.5/24`), service endpoints are
service names, and `security_group` and `nat_gateway` take an ARM id, not
a name. `limits` has the rules.

## Errors

`Error` is closed: core's ARM refusals by status (`BadRequest`,
`NotFound`, `Conflict`, `PermissionDenied`, `Throttled`, `ServerError` and
the rest), `ProviderNotRegistered` for a subscription that has not
registered Microsoft.Network, the transport's and the token provider's
failures, `InvalidArgument` for what was refused before sending,
`InvalidResponse` for an answer that is not ARM's JSON, and
`InvalidOperation` for a write whose answer cannot be followed. After a
failure, `Diagnostics` has the status, Network's code and message, and the
request ids. Calls are retried on 408, 429 and 5xx with backoff, waiting
what ARM asks up to a minute.

Making networks and security groups needs Network Contributor, or
Contributor, where they go; a VM's network interface joining a subnet in
another resource group needs `subnets/join/action` there.

## Testing code that uses this module

`testing.FakeNetwork` is Microsoft.Network in memory, behind
`Options.transport`: networks, subnets and security groups in the resource
groups a test adds (`addGroup`), each write an operation answered
`InProgress` for `operation_polls` polls. It refuses what Network refuses,
with Network's codes; `useSubnet` puts a network interface in a subnet so
it is in use, `failNextWrite` makes the next create's operation fail,
`addNatGateway` gives a subnet a NAT gateway to name, and `registered =
false` refuses every call as an unregistered subscription is. Give the
client `testing.FakeClock`'s `io` and the polls take no time.

<!-- snippet: tests/docs_examples.zig#fake-network -->
```zig
var fake: network.testing.FakeNetwork = .init(gpa);
defer fake.deinit();
try fake.addGroup("0f9e8d7c-6b5a-4c3d-8e2f-1a0b9c8d7e6f", "rg");
var clock: network.testing.FakeClock = .{};
var token: network.StaticToken = .{ .token = "t" };
var client: network.Client = try .init(gpa, clock.io(), .{
    .token_provider = token.provider(),
    .transport = fake.transport(),
});
defer client.deinit();
```

The NAT gateway itself, and the public IPs it needs, are not made here
yet.
