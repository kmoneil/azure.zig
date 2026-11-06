[Docs](../README.md) › Prices

# prices: VM prices from the Retail Prices API

What a Linux VM size costs an hour, spot or on demand, in each region, from
Azure's public Retail Prices API. It needs no credentials, and the client
never sends any. Measured against the API on 2026-11-06; the live suite
(`tests/prices_azure_integration.zig`) runs it again.

## A first program

```zig
const std = @import("std");
const prices = @import("prices");

pub fn main(init: std.process.Init) !void {
    var client: prices.Client = try .init(init.gpa, init.io, .{});
    defer client.deinit();

    var spot = try client.list(.{ .sku = "Standard_D2as_v5" });
    defer spot.deinit();
    for (spot.value.prices) |p| std.debug.print("{s}  {f} {s}/h\n", .{ p.region, p.per_hour, p.currency });
}
```

## The calls

| Call | Does |
| --- | --- |
| `list(query)` | Every Linux price `query` names, every page read: one per size and region |
| `cheapest(query)` | The lowest of them, or null when the query names none |

A `Query` names the `pricing` (`.spot`, the default, or `.on_demand`), and
optionally a `region` (`eastus2`) and a `sku` (`Standard_D2as_v5`). Both
compare with case, as the API does: `EastUS2` matches nothing there, so
the client refuses it. `Options.currency` asks for prices in another
currency, as `EUR`.

## Which rows count

One size in one region is about a dozen rows in the API; one of them is
the Linux spot price and one the Linux on-demand price. The rest, which
the client leaves out:

- Windows (`productName` ends in ` Windows`), and Dev/Test prices;
- reservations, priced per term though their unit says `1 Hour`;
- the legacy `Low Priority` meters, which spot replaced;
- Cloud Services (`productName` such as `Dasv5 Series Cloud Services`),
  which are not VM prices.

The client asks the API for exactly the rows it wants and checks each row
again as it reads it; `PriceList.skipped` counts any a check left out. Key
on `sku` (ARM's `armSkuName`): the API's own `skuName` is spelled
inconsistently from one family to the next.

## Amounts

`Amount` holds whole units and billionths, read from the number's own
digits, never through a float: `0.015919` is exactly 15,919,000
billionths. The API writes at most seven decimals (measured); a price
finer than a billionth is refused rather than rounded. `{f}` writes an
amount back as a decimal.

## Pages and limits

The API answers 1000 rows a page and writes each next page's link with
the default port spelled out (`https://prices.azure.com:443/...`); the
client follows it as the same origin, and no link elsewhere. The API's
limits are undocumented: its answers carry
`x-ms-ratelimit-remaining-retailprices-requests` and
`x-ms-ratelimit-retailprices-retry-after: 60`. A refusal is retried on
408, 429 and 5xx with backoff.

## Errors

`Error` is closed: the API's refusals (`BadRequest` for an OData filter it
will not take, `Throttled`, `ServerError` and the rest), the transport's
failures, `InvalidArgument` for a region, size or currency refused before
sending, and `InvalidResponse` for an answer that is not the API's JSON.
`Diagnostics` has the API's code and message, which it writes as
`{"Error":{"Code","Message"}}`.

## Testing code that uses this module

`testing.FakePrices` is the API in memory, behind `Options.transport`.
`addSize` adds the rows production lists for one size in one region,
those to leave out included; `addRow` adds any row. It filters by the
OData the client sends, with case, and pages with production's links.

```zig
var fake: prices.testing.FakePrices = .init(gpa);
defer fake.deinit();
try fake.addSize("eastus2", "Standard_D2as_v5", "Dasv5", "0.015919", "0.086");
var client: prices.Client = try .init(gpa, io, .{ .transport = fake.transport() });
defer client.deinit();
```
