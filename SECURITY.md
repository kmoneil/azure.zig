# Security

This package will hold credentials for somebody's Azure account: bearer
tokens for Azure Resource Manager and Storage, and in `auth`, what mints
them (a client secret, a certificate's private key, a managed identity's
endpoint). `storage` will also hold account keys and the SAS tokens it
signs with them. Two things follow from that, and this document is about
both: no credential may leak, and nothing a server or network peer sends
may crash the client or pass a partial response off as a whole one.

## Reporting a vulnerability

Email **kevin@oneil.xyz**. Please do not open a public issue for a
vulnerability.

You will get an acknowledgement within 3 working days. Fixed issues are
disclosed publicly within **90 days** of the report, sooner if a fix ships
earlier, later only by agreement with the reporter.

Include the version, the call, and if you can, the response that triggers
it.

## Supported versions

Pre-1.0, and not released yet. Until the v1.0 tag, only the latest release
receives fixes.

## Threat model

**Assumed hostile: everything a server sends.** Production is reached over
TLS, but Azurite and the metadata endpoints speak plain HTTP, and a proxy
or a compromised peer can say anything. A response is parsed, never
trusted.

**Assumed trusted: the caller.** Arguments and options are the
application's own instructions. A mistake in them is still an error, never
a crash or a malformed request.

**Out of scope:** an attacker who already has a token or a key, or can read
the credentials the program was given; a compromised machine; and the
behavior of Azurite itself.

Each guarantee joins this document with the code that makes it, naming the
test that holds it.

## Known gaps

### TLS takes a certificate signed by one that is not a CA

Zig 0.17.1's `std.crypto.tls.Client` checks each certificate in the
server's chain against the next by signature and issuer alone, and trusts
the chain once any certificate's issuer is in the bundle.
`std.crypto.Certificate` never reads basicConstraints' cA flag or
keyUsage's keyCertSign, so it never checks that an issuer is a CA at all.
This is CWE-296; upstream, Codeberg ziglang/zig#35877 and #37353, both
open.

So anyone holding a certificate a trusted root signed, for a domain of
their own, can sign one for `login.microsoftonline.com` or
`management.azure.com`, and a man in the middle that presents the two is
trusted. Any client on `std.http.Client` would then hand over its bearer
token, and on a token request, its client secret or the assertion a
certificate credential signs.

azure.zig will reach Azure through `std.http.Client`, so it inherits this
until std ships a fix or the transport carries one; this section says
which when either lands.
