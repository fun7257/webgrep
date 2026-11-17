const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const SESSION_COOKIE_NAME: []const u8 = "webgrep_session";
pub const SESSION_TTL_SECONDS: u64 = 30 * 24 * 60 * 60; // 30 days

pub const LoginRequest = struct {
    password: ?[]const u8 = null,
};

pub const AuthStatusDto = struct {
    authRequired: bool,
    authenticated: bool,
    mcpTokenRequired: bool,
};

pub const AuthGuard = struct {
    has_web_password: bool = false,
    web_password_sha256: [Sha256.digest_length]u8 = @splat(0),
    cookie_hmac_key: [HmacSha256.mac_length]u8 = @splat(0),
    has_mcp_token: bool = false,
    mcp_token_sha256: [Sha256.digest_length]u8 = @splat(0),

    pub fn init(raw_web_password: ?[]const u8, raw_mcp_token: ?[]const u8) AuthGuard {
        var guard = AuthGuard{};

        if (raw_web_password) |raw_pw| {
            const stripped_nl = std.mem.trim(u8, raw_pw, "\r\n");
            if (std.mem.trim(u8, stripped_nl, " \t").len > 0) {
                guard.has_web_password = true;
                Sha256.hash(stripped_nl, &guard.web_password_sha256, .{});
                HmacSha256.create(&guard.cookie_hmac_key, "webgrep-cookie-signing-key-v1", stripped_nl);
            }
        }

        if (raw_mcp_token) |raw_tok| {
            const trimmed_tok = std.mem.trim(u8, raw_tok, " \t\r\n");
            if (trimmed_tok.len > 0) {
                guard.has_mcp_token = true;
                Sha256.hash(trimmed_tok, &guard.mcp_token_sha256, .{});
            }
        }

        return guard;
    }

    pub fn webPasswordRequired(self: *const AuthGuard) bool {
        return self.has_web_password;
    }

    pub fn mcpTokenRequired(self: *const AuthGuard) bool {
        return self.has_mcp_token;
    }

    pub fn verifyWebPassword(self: *const AuthGuard, candidate: []const u8) bool {
        if (!self.has_web_password) return true;
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(candidate, &digest, .{});
        return std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest, self.web_password_sha256);
    }

    pub fn verifyMcpToken(self: *const AuthGuard, candidate: []const u8) bool {
        if (!self.has_mcp_token) return true;
        const trimmed = std.mem.trim(u8, candidate, " \t\r\n");
        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(trimmed, &digest, .{});
        return std.crypto.timing_safe.eql([Sha256.digest_length]u8, digest, self.mcp_token_sha256);
    }

    pub fn issueSessionTokenAlloc(
        self: *const AuthGuard,
        alloc: std.mem.Allocator,
        io: std.Io,
        now_sec: u64,
    ) ![]u8 {
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const nonce_hex = std.fmt.bytesToHex(nonce, .lower);
        const exp_sec: u64 = now_sec + SESSION_TTL_SECONDS;

        const payload = try std.fmt.allocPrint(alloc, "{d}.{s}", .{ exp_sec, nonce_hex });
        defer alloc.free(payload);

        var mac: [HmacSha256.mac_length]u8 = undefined;
        var hmac = HmacSha256.init(&self.cookie_hmac_key);
        hmac.update("webgrep-session-v1|");
        hmac.update(payload);
        hmac.final(&mac);

        const mac_hex = std.fmt.bytesToHex(mac, .lower);
        return std.fmt.allocPrint(alloc, "{s}.{s}", .{ payload, mac_hex });
    }

    pub fn verifySessionToken(self: *const AuthGuard, token: []const u8, now_sec: u64) bool {
        if (!self.has_web_password) return true;
        const trimmed = std.mem.trim(u8, token, " \t\r\n");
        if (trimmed.len == 0) return false;

        const dot1 = std.mem.indexOfScalar(u8, trimmed, '.') orelse return false;
        const exp_str = trimmed[0..dot1];
        const rest = trimmed[dot1 + 1 ..];
        const dot2 = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const nonce_hex = rest[0..dot2];
        const mac_hex = rest[dot2 + 1 ..];

        if (exp_str.len == 0 or nonce_hex.len != 32 or mac_hex.len != HmacSha256.mac_length * 2) {
            return false;
        }

        const exp_sec = std.fmt.parseInt(u64, exp_str, 10) catch return false;
        if (exp_sec <= now_sec) return false;

        // Ensure nonce contains only hex characters to prevent malformed tokens
        var nonce_bytes: [16]u8 = undefined;
        _ = std.fmt.hexToBytes(&nonce_bytes, nonce_hex) catch return false;

        var provided_mac: [HmacSha256.mac_length]u8 = undefined;
        _ = std.fmt.hexToBytes(&provided_mac, mac_hex) catch return false;

        const payload = trimmed[0 .. dot1 + 1 + nonce_hex.len];
        var expected_mac: [HmacSha256.mac_length]u8 = undefined;
        var hmac = HmacSha256.init(&self.cookie_hmac_key);
        hmac.update("webgrep-session-v1|");
        hmac.update(payload);
        hmac.final(&expected_mac);

        return std.crypto.timing_safe.eql([HmacSha256.mac_length]u8, expected_mac, provided_mac);
    }

    pub fn isWebRequestAuthenticated(
        self: *const AuthGuard,
        cookie_header: []const u8,
        authorization_header: []const u8,
        now_sec: u64,
    ) bool {
        if (!self.has_web_password) return true;

        if (extractCookieValue(cookie_header, SESSION_COOKIE_NAME)) |cookie_tok| {
            if (self.verifySessionToken(cookie_tok, now_sec)) return true;
        }

        if (extractBearerOrCustomToken(authorization_header, "")) |bearer_tok| {
            if (self.verifySessionToken(bearer_tok, now_sec)) return true;
            if (self.verifyWebPassword(bearer_tok)) return true;
        }

        return false;
    }

    pub fn isMcpRequestAuthenticated(
        self: *const AuthGuard,
        authorization_header: []const u8,
        x_mcp_token_header: []const u8,
    ) bool {
        if (!self.has_mcp_token) return true;
        const tok = extractBearerOrCustomToken(authorization_header, x_mcp_token_header) orelse return false;
        return self.verifyMcpToken(tok);
    }
};

pub fn buildSetCookieHeaderAlloc(
    alloc: std.mem.Allocator,
    token: []const u8,
    secure: bool,
) ![]u8 {
    if (secure) {
        return std.fmt.allocPrint(
            alloc,
            "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}; Secure",
            .{ SESSION_COOKIE_NAME, token, SESSION_TTL_SECONDS },
        );
    }
    return std.fmt.allocPrint(
        alloc,
        "{s}={s}; Path=/; HttpOnly; SameSite=Lax; Max-Age={d}",
        .{ SESSION_COOKIE_NAME, token, SESSION_TTL_SECONDS },
    );
}

pub fn buildClearCookieHeader() []const u8 {
    return SESSION_COOKIE_NAME ++ "=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0";
}

pub fn extractCookieValue(cookie_header: []const u8, cookie_name: []const u8) ?[]const u8 {
    if (cookie_header.len == 0 or cookie_name.len == 0) return null;
    var it = std.mem.splitScalar(u8, cookie_header, ';');
    while (it.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t\r\n");
        if (pair.len == 0) continue;
        const eq_idx = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = std.mem.trim(u8, pair[0..eq_idx], " \t");
        if (!std.mem.eql(u8, name, cookie_name)) continue;
        var val = std.mem.trim(u8, pair[eq_idx + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }
        return val;
    }
    return null;
}

pub fn extractBearerOrCustomToken(
    authorization_header: []const u8,
    custom_token_header: []const u8,
) ?[]const u8 {
    const trimmed_auth = std.mem.trim(u8, authorization_header, " \t\r\n");
    const bearer_prefix = "Bearer ";
    if (trimmed_auth.len > bearer_prefix.len and
        std.ascii.eqlIgnoreCase(trimmed_auth[0..bearer_prefix.len], bearer_prefix))
    {
        const tok = std.mem.trim(u8, trimmed_auth[bearer_prefix.len..], " \t");
        if (tok.len > 0) return tok;
    }

    const trimmed_custom = std.mem.trim(u8, custom_token_header, " \t\r\n");
    if (trimmed_custom.len > 0) return trimmed_custom;

    return null;
}

test "disabled auth passes everything through" {
    const guard = AuthGuard.init(null, "   ");
    try std.testing.expect(!guard.webPasswordRequired());
    try std.testing.expect(!guard.mcpTokenRequired());
    try std.testing.expect(guard.verifyWebPassword("anything"));
    try std.testing.expect(guard.verifyMcpToken(""));
    try std.testing.expect(guard.isWebRequestAuthenticated("", "", 1000));
    try std.testing.expect(guard.isMcpRequestAuthenticated("", ""));
}

test "web password verification and edge cases" {
    const guard = AuthGuard.init("s3cr3t-密码\r\n", null);
    try std.testing.expect(guard.webPasswordRequired());
    try std.testing.expect(!guard.mcpTokenRequired());

    try std.testing.expect(guard.verifyWebPassword("s3cr3t-密码"));
    try std.testing.expect(!guard.verifyWebPassword("s3cr3t-密码2"));
    try std.testing.expect(!guard.verifyWebPassword("short"));
    try std.testing.expect(!guard.verifyWebPassword(""));
}

test "mcp token verification and header extraction" {
    const guard = AuthGuard.init(null, "  mcp-tok-42 \n");
    try std.testing.expect(!guard.webPasswordRequired());
    try std.testing.expect(guard.mcpTokenRequired());

    try std.testing.expect(guard.verifyMcpToken("mcp-tok-42"));
    try std.testing.expect(!guard.verifyMcpToken("wrong-tok"));

    try std.testing.expect(guard.isMcpRequestAuthenticated("Bearer mcp-tok-42", ""));
    try std.testing.expect(guard.isMcpRequestAuthenticated("bearer mcp-tok-42", ""));
    try std.testing.expect(guard.isMcpRequestAuthenticated("", "mcp-tok-42"));
    try std.testing.expect(!guard.isMcpRequestAuthenticated("Bearer wrong", ""));
    try std.testing.expect(!guard.isMcpRequestAuthenticated("", ""));
}

test "session token issuance, verification, tamper, expiry, and rotation" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    const guard = AuthGuard.init("deploy-pass-1", null);
    const now_sec: u64 = 1_700_000_000;
    const token = try guard.issueSessionTokenAlloc(alloc, io, now_sec);
    defer alloc.free(token);

    try std.testing.expect(guard.verifySessionToken(token, now_sec + 10));
    // Expired
    try std.testing.expect(!guard.verifySessionToken(token, now_sec + SESSION_TTL_SECONDS + 1));

    // Tampered character
    const tampered = try alloc.dupe(u8, token);
    defer alloc.free(tampered);
    tampered[tampered.len - 1] = if (tampered[tampered.len - 1] == 'a') 'b' else 'a';
    try std.testing.expect(!guard.verifySessionToken(tampered, now_sec + 10));

    // Rotated password invalidates previous session
    const rotated = AuthGuard.init("deploy-pass-2", null);
    try std.testing.expect(!rotated.verifySessionToken(token, now_sec + 10));

    // Cookie & bearer auth checks
    const cookie_hdr = try std.fmt.allocPrint(alloc, "foo=bar; {s}=\"{s}\"; theme=dark", .{
        SESSION_COOKIE_NAME,
        token,
    });
    defer alloc.free(cookie_hdr);
    try std.testing.expect(guard.isWebRequestAuthenticated(cookie_hdr, "", now_sec + 10));
    try std.testing.expect(!guard.isWebRequestAuthenticated("other=123", "", now_sec + 10));
    try std.testing.expect(guard.isWebRequestAuthenticated("", "Bearer deploy-pass-1", now_sec + 10));
    try std.testing.expect(!guard.isWebRequestAuthenticated("", "Bearer wrong-pass", now_sec + 10));
}

test "set-cookie formatting" {
    const alloc = std.testing.allocator;
    const plain = try buildSetCookieHeaderAlloc(alloc, "tok.123.abc", false);
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "webgrep_session=tok.123.abc; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "Secure") == null);

    const sec = try buildSetCookieHeaderAlloc(alloc, "tok.123.abc", true);
    defer alloc.free(sec);
    try std.testing.expect(std.mem.endsWith(u8, sec, "; Secure"));
}
