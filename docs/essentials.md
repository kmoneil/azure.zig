[Docs](README.md) › Essentials

# Essentials

What every module shares. Nothing is here yet: each section is written
with the code it describes, as `core` and the first modules land.

- **Clients and handles**: how a client is made and freed, what its
  handles borrow, and which may be shared between tasks.
- **Endpoints and clouds**: Azure's public cloud by default, the national
  clouds, and Azurite for Blob Storage.
- **Results and memory**: what a call returns and who frees it.
- **Errors and diagnostics**: the error sets, ARM's and Blob's error
  bodies, and the request id to quote to Azure support.
- **Retries, time limits and cancellation**: what is retried and how long
  a call may take.
- **Logging**: the scopes each module logs under, and what is never
  logged.
- **Testing code that uses this library**: the in-memory fakes.
