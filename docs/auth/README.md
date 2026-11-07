[Docs](../README.md) › Auth

# auth: credentials

Tokens for every module, through core's `TokenProvider`. `ClientSecret`
signs an app in to Entra ID with a client secret; `AzureCli` takes the
Azure CLI's login on a developer's machine; `StaticToken` holds a token
got some other way. Each caches its tokens per scope, so one credential
serves Resource Manager, Storage and any other client at once, and each
is safe to share between tasks.

Measured against Entra ID and az 2.92.0 on 2026-11-07. The live suite
(`tests/auth_azure_integration.zig`) runs it again.

## A first program

It lists the subscriptions a credential can see: an app's, when
`AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and `AZURE_CLIENT_SECRET` are set,
else whoever `az login` signed in.

<!-- snippet: examples/auth_subscriptions.zig -->
```zig
const std = @import("std");
const auth = @import("auth");
const resources = @import("resources");

pub fn main(init: std.process.Init) !void {
    const env = init.environ_map;
    var diag: auth.Diagnostics = .{};

    // An app's own sign-in when AZURE_TENANT_ID, AZURE_CLIENT_ID and
    // AZURE_CLIENT_SECRET are set; else the Azure CLI's (az login).
    var cli: auth.AzureCli = try .init(init.gpa, .{ .diagnostics = &diag });
    defer cli.deinit();
    var secret: ?auth.ClientSecret = null;
    defer if (secret) |*s| s.deinit();
    if (env.get("AZURE_CLIENT_SECRET")) |value| {
        secret = auth.ClientSecret.init(init.gpa, init.io, .{
            .tenant_id = env.get("AZURE_TENANT_ID") orelse "",
            .client_id = env.get("AZURE_CLIENT_ID") orelse "",
            .secret = value,
            .diagnostics = &diag,
        }) catch |err| {
            std.debug.print("{t}: {f}\n", .{ err, diag });
            return err;
        };
    }
    const provider = if (secret) |*s| s.provider() else cli.provider();

    // One credential serves every client; each asks its own scope.
    var client: resources.Client = try .init(init.gpa, init.io, .{
        .token_provider = provider,
        .diagnostics = &diag,
    });
    defer client.deinit();
    var subscriptions = client.listSubscriptions() catch |err| {
        std.debug.print("{t}: {f}\n", .{ err, diag });
        return err;
    };
    defer subscriptions.deinit();
    for (subscriptions.value) |s| std.debug.print("{s}  {s}\n", .{ s.id, s.display_name });
}
```

## The credentials

| Credential | Signs in as | Needs |
| --- | --- | --- |
| `ClientSecret` | An app registration (a service principal) | Its tenant, its client id, and a secret's value |
| `AzureCli` | Whoever `az login` signed in: a user or a service principal | `az` on the PATH, 2.54.0 or later |
| `StaticToken` | Whoever the token is for | A token, which never refreshes |

Each is made with `init`, freed with `deinit`, and handed to a client as
`provider()`, which must not outlive it.

## Scopes and the cache

A client asks for one scope, a resource's `/.default`: Resource Manager's
is `https://management.core.windows.net//.default` (the double slash
intended) and Storage's `https://storage.azure.com/.default`. An app's
sign-in takes nothing else, and Entra refuses a scope without
`/.default` (AADSTS1002012); the credential refuses one first.

<!-- snippet: tests/docs_examples.zig#two-scopes -->
```zig
// One credential, a token per scope, each cached until five minutes
// before it expires.
const p = cred.provider();
const for_arm = try p.getToken(io, arena.allocator(), &.{"https://management.core.windows.net//.default"});
const for_blobs = try p.getToken(io, arena.allocator(), &.{"https://storage.azure.com/.default"});
```

A token is fetched once and handed out from memory until five minutes
before it expires, or sooner when Entra sends `refresh_in`; one that lives
under ten minutes is refreshed at half its life. One fetch runs at a
time. When an early refresh fails, the token still valid is used, and
another try comes 30 s later; past expiry, the failure is the call's.
After a 401, a client calls `invalidate`, and every token is fetched
again. Entra's tokens live 3599 s from their arrival, which is what the
cache counts from: a token's own `iat` is set five minutes back. Tokens,
secrets and the memory that held them are wiped before they are freed.

## ClientSecret

The client credentials grant at
`{authority host}{tenant}/oauth2/v2.0/token`. The tenant is its id or a
domain, such as `contoso.onmicrosoft.com`; `common`, `organizations` and
`consumers` choose a tenant by the user signing in, which an app has none
of, and Entra refuses them (AADSTS700016). The client id is the app's id,
a GUID; the secret is its value, not its id. `cloud` picks the authority
host (`login.microsoftonline.com` for the public cloud), or
`authority_host` names another, over HTTPS.

Requests go four times at most on 408, 429 and 5xx, and on a dropped
connection, waiting what Entra asks. A refusal goes to `Diagnostics`:
the status, Entra's `error` (`invalid_client`), the description up to its
ids (`AADSTS7000215: Invalid client secret provided...`), and the trace
and correlation ids Entra's support asks for.

## AzureCli

Runs `az account get-access-token --output json --resource <resource>`,
with `--tenant` when `tenant_id` is set, and waits 10 s for it
(`timeout_ms`). On Windows `az` is a batch file, run through `cmd.exe`,
so the resource and tenant are held to the characters a URL needs before
they go on its command line. The token's expiry is `expires_on`, which az
2.54.0 and later print; an older az prints only `expiresOn`, a local time
with no zone, and is refused with that said. No `az` is
`CredentialSourceUnavailable`.

az ends every refusal with a hint to log in again, whatever the cause;
only "Please run 'az login'" and the codes of a lapsed sign-in (an expired
or revoked refresh token, multi-factor authentication asked again) are
`ReauthenticationRequired`. `Diagnostics` has az's first `ERROR:` line,
which never holds a token.

## Errors

A credential's errors are `TokenProvider.Error`, which every module's
error set includes:

| Error | Means |
| --- | --- |
| `TokenEndpointRejected` | Entra, or az, refused: a wrong secret, an unknown app or tenant, an unknown resource |
| `ReauthenticationRequired` | The credential has lapsed: an expired secret (AADSTS7000222), a sign-in to run again |
| `CredentialSourceUnavailable` | No source on this machine: no `az` |
| `TokenUnavailable` | Entra stayed down through every try, az took too long, or a scope was refused before sending |
| `InvalidTokenResponse` | An answer with no usable token or expiry |

and the transport's own failures. `init` returns `InvalidArgument` for
options that cannot work, with `Diagnostics` saying which.

## Testing code that uses this module

`testing.FakeEntra` is Entra's token endpoint in memory, behind
`ClientSecret.Options.transport`: apps added with `addApp`, tokens that
live `expires_in` and carry `refresh_in` when set, and each refusal as
Entra sent it, with its AADSTS code. `fail_next` answers the next request
as given; `issued` lists the scope of every token handed out. Give the
credential `testing.FakeClock`'s `io`, and move the clock to see a token
refreshed.

<!-- snippet: tests/docs_examples.zig#fake-entra -->
```zig
var fake: auth.testing.FakeEntra = .init(gpa);
defer fake.deinit();
try fake.addApp("00000000-0000-4000-8000-00000000aaaa", "00000000-0000-4000-8000-00000000a99a", "the-secret");
var cred: auth.ClientSecret = try .init(gpa, io, .{
    .tenant_id = "00000000-0000-4000-8000-00000000aaaa",
    .client_id = "00000000-0000-4000-8000-00000000a99a",
    .secret = "the-secret",
    .transport = fake.transport(),
});
defer cred.deinit();
```

`AzureCli.Options.runner` runs `az` in place of the process, for a test
that needs no CLI.

Managed identity comes next (m2); a certificate and workload identity
after (m3); then a default chain that finds whichever is there (m4).
