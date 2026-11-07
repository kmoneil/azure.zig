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
