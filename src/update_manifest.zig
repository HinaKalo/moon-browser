const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
pub const package_limit = 64 * 1024 * 1024;
const key_id = "f5faa9f9858b789f";
const public_key = "k4thZR+OVYSGAT/9j5F39csgGqTL0t3X6GYdNCmuRI8=";

pub const Target = struct {
    app: []const u8,
    platform: []const u8,
    channel: []const u8,
    suffix: []const u8,
};

const Manifest = struct {
    app: []const u8,
    platform: []const u8,
    channel: []const u8,
    versionCode: u64,
    versionName: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
    minVersionCode: u64,
    notes: ?[]const u8 = null,
    publishedAt: []const u8,
    keyId: []const u8,
    signature: []const u8,
};
const Response = struct { manifest: ?Manifest = null };

pub const Package = struct {
    code: u64,
    version: [65:0]u8 = @splat(0),
    filename: [129:0]u8 = @splat(0),
    size: u64,
    hash: [32]u8,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn validToken(value: []const u8, max: usize, extra: []const u8) bool {
    if (value.len == 0 or value.len > max or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, extra, c) == null) return false;
    return true;
}

pub fn parse(body: []const u8, target: Target, current: u64) !?Package {
    const parsed = try std.json.parseFromSlice(Response, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const m = parsed.value.manifest orelse return null;
    if (!eql(m.app, target.app) or !eql(m.platform, target.platform) or !eql(m.channel, target.channel))
        return error.WrongTarget;
    if (!eql(m.keyId, key_id) or m.size == 0 or m.size > package_limit or m.minVersionCode > m.versionCode or
        m.sha256.len != 64 or !validToken(m.versionName, 64, "-.+") or
        !validToken(m.file, 128, "-._") or !std.mem.endsWith(u8, m.file, target.suffix) or
        !validToken(m.publishedAt, 48, "-:.+")) return error.InvalidManifest;

    var pkg: Package = .{ .code = m.versionCode, .size = m.size, .hash = undefined };
    _ = std.fmt.hexToBytes(&pkg.hash, m.sha256) catch return error.InvalidManifest;
    var notes_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(m.notes orelse "", &notes_digest, .{});
    const notes_hex = std.fmt.bytesToHex(notes_digest, .lower);
    var data: [1024]u8 = undefined;
    const signed = try std.fmt.bufPrint(&data, "relhub-release-v1\napp={s}\nplatform={s}\nchannel={s}\nversionCode={d}\nversionName={s}\n" ++
        "file={s}\nsize={d}\nsha256={s}\nminVersionCode={d}\npublishedAt={s}\nnotesSha256={s}\n", .{ m.app, m.platform, m.channel, m.versionCode, m.versionName, m.file, m.size, m.sha256, m.minVersionCode, m.publishedAt, notes_hex });
    var pk_bytes: [Ed25519.PublicKey.encoded_length]u8 = undefined;
    var sig_bytes: [Ed25519.Signature.encoded_length]u8 = undefined;
    try std.base64.standard.Decoder.decode(&pk_bytes, public_key);
    std.base64.standard.Decoder.decode(&sig_bytes, m.signature) catch return error.InvalidSignature;
    const key = try Ed25519.PublicKey.fromBytes(pk_bytes);
    Ed25519.Signature.fromBytes(sig_bytes).verifyStrict(signed, key) catch return error.InvalidSignature;
    if (m.versionCode <= current) return null;
    @memcpy(pkg.version[0..m.versionName.len], m.versionName);
    @memcpy(pkg.filename[0..m.file.len], m.file);
    return pkg;
}
