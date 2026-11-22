const std = @import("std");
const prefilter = @import("../../prefilter.zig");
const line_time = @import("line_time.zig");

const sliceAtLineEnd = line_time.sliceAtLineEnd;

pub const KvPredicate = prefilter.KvPredicate;
pub const KvOp = prefilter.KvOp;

// ============================================================================
// Allocation-Free KV Predicate Verifier (JSON + logfmt)
// ============================================================================

pub const ExtractedVal = struct {
    raw: []const u8,
    is_quoted: bool = false,
    is_null: bool = false,
};

fn skipJsonString(s: []const u8, open_quote_idx: usize) ?usize {
    var i = open_quote_idx + 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') return i + 1;
    }
    return null;
}

fn jsonKeyEquals(raw_key: []const u8, target: []const u8) bool {
    if (std.mem.indexOfScalar(u8, raw_key, '\\') == null) {
        return std.mem.eql(u8, raw_key, target);
    }
    // Escape-aware equality without heap allocation
    var ri: usize = 0;
    var ti: usize = 0;
    while (ri < raw_key.len and ti < target.len) {
        var ch = raw_key[ri];
        if (ch == '\\' and ri + 1 < raw_key.len) {
            ri += 1;
            ch = switch (raw_key[ri]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => raw_key[ri],
            };
        }
        if (ch != target[ti]) return false;
        ri += 1;
        ti += 1;
    }
    return ri == raw_key.len and ti == target.len;
}

fn skipJsonValue(s: []const u8, start_idx: usize) ?usize {
    var i = start_idx;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len) return null;
    if (s[i] == '"') return skipJsonString(s, i);
    if (s[i] == '{' or s[i] == '[') {
        var depth: usize = 0;
        while (i < s.len) {
            if (s[i] == '"') {
                i = skipJsonString(s, i) orelse return null;
                continue;
            }
            if (s[i] == '{' or s[i] == '[') {
                depth += 1;
            } else if (s[i] == '}' or s[i] == ']') {
                depth -= 1;
                if (depth == 0) return i + 1;
            }
            i += 1;
        }
        return null;
    }
    while (i < s.len and s[i] != ',' and s[i] != '}' and s[i] != ']' and s[i] != ' ' and s[i] != '\t' and s[i] != '\r' and s[i] != '\n') : (i += 1) {}
    return i;
}

fn extractJsonSingleSegment(obj: []const u8, key_seg: []const u8) ?ExtractedVal {
    const start = std.mem.indexOfScalar(u8, obj, '{') orelse return null;
    var i: usize = start + 1;
    while (i < obj.len) {
        while (i < obj.len and (obj[i] == ' ' or obj[i] == '\t' or obj[i] == ',' or obj[i] == '\r' or obj[i] == '\n')) : (i += 1) {}
        if (i >= obj.len or obj[i] == '}') return null;
        if (obj[i] != '"') {
            i += 1;
            continue;
        }
        const k_end = skipJsonString(obj, i) orelse return null;
        const raw_key = obj[i + 1 .. k_end - 1];
        var pos = k_end;
        while (pos < obj.len and (obj[pos] == ' ' or obj[pos] == '\t')) : (pos += 1) {}
        if (pos >= obj.len or obj[pos] != ':') {
            i = k_end;
            continue;
        }
        pos += 1;
        while (pos < obj.len and (obj[pos] == ' ' or obj[pos] == '\t')) : (pos += 1) {}
        if (pos >= obj.len) return null;

        if (jsonKeyEquals(raw_key, key_seg)) {
            if (obj[pos] == '"') {
                const v_end = skipJsonString(obj, pos) orelse return null;
                return .{ .raw = obj[pos + 1 .. v_end - 1], .is_quoted = true, .is_null = false };
            } else if (obj[pos] == '{' or obj[pos] == '[') {
                const v_end = skipJsonValue(obj, pos) orelse return null;
                return .{ .raw = obj[pos..v_end], .is_quoted = false, .is_null = false };
            } else {
                var v_end = pos;
                while (v_end < obj.len and obj[v_end] != ',' and obj[v_end] != '}' and obj[v_end] != ']' and obj[v_end] != ' ' and obj[v_end] != '\t' and obj[v_end] != '\r' and obj[v_end] != '\n') : (v_end += 1) {}
                const tok = obj[pos..v_end];
                return .{
                    .raw = tok,
                    .is_quoted = false,
                    .is_null = std.mem.eql(u8, tok, "null"),
                };
            }
        }
        i = skipJsonValue(obj, pos) orelse return null;
    }
    return null;
}

pub fn extractJsonFieldRaw(json_obj: []const u8, dotted_key: []const u8) ?ExtractedVal {
    if (std.mem.indexOfScalar(u8, dotted_key, '.') == null) {
        return extractJsonSingleSegment(json_obj, dotted_key);
    }
    // Try literal dotted key at top level first (e.g. `{"http.status": 200}`), then traverse nested objects
    if (extractJsonSingleSegment(json_obj, dotted_key)) |direct| return direct;
    var cur_slice = json_obj;
    var it = std.mem.splitScalar(u8, dotted_key, '.');
    while (it.next()) |seg| {
        const val = extractJsonSingleSegment(cur_slice, seg) orelse return null;
        if (it.peek() == null) return val;
        if (val.is_quoted or val.raw.len == 0 or val.raw[0] != '{') return null;
        cur_slice = val.raw;
    }
    return null;
}

pub fn extractLogfmtFieldRaw(line: []const u8, target_key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\r' or line[i] == '\n')) : (i += 1) {}
        if (i >= line.len) break;

        if (line[i] == '"') {
            i = skipJsonString(line, i) orelse break;
            continue;
        }

        const tok_start = i;
        var eq_pos: ?usize = null;
        while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '\r' and line[i] != '\n') : (i += 1) {
            if (line[i] == '=' and eq_pos == null) {
                eq_pos = i;
                break;
            }
        }

        const eq = eq_pos orelse continue;
        const key_slice = line[tok_start..eq];
        const vstart = eq + 1;
        var val_slice: []const u8 = "";
        if (vstart >= line.len or line[vstart] == ' ' or line[vstart] == '\t' or line[vstart] == '\r' or line[vstart] == '\n') {
            i = vstart;
        } else if (line[vstart] == '"') {
            const vend = skipJsonString(line, vstart) orelse break;
            val_slice = line[vstart + 1 .. vend - 1];
            i = vend;
        } else {
            var vend = vstart;
            while (vend < line.len and line[vend] != ' ' and line[vend] != '\t' and line[vend] != '\r' and line[vend] != '\n') : (vend += 1) {}
            val_slice = line[vstart..vend];
            i = vend;
        }

        if (std.mem.eql(u8, key_slice, target_key)) {
            return val_slice;
        }
    }
    return null;
}

fn decodeEscapedToStack(raw: []const u8, buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out_len: usize = 0;
    var i: usize = 0;
    while (i < raw.len and out_len < buf.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            i += 1;
            buf[out_len] = switch (raw[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => raw[i],
            };
        } else {
            buf[out_len] = raw[i];
        }
        out_len += 1;
        i += 1;
    }
    return buf[0..out_len];
}

fn eqStrings(a: []const u8, b: []const u8, case_sensitive: bool) bool {
    return if (case_sensitive) std.mem.eql(u8, a, b) else std.ascii.eqlIgnoreCase(a, b);
}

fn containsString(haystack: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    if (case_sensitive) return std.mem.indexOf(u8, haystack, needle) != null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn evalExtractedKv(val_opt: ?ExtractedVal, pred: KvPredicate) bool {
    const val = val_opt orelse {
        return pred.op == .neq;
    };
    if (val.is_null) {
        return pred.op == .neq;
    }
    var scratch: [1024]u8 = undefined;
    const text = decodeEscapedToStack(val.raw, &scratch);

    switch (pred.op) {
        .exists => return true,
        .eq => {
            if (eqStrings(text, pred.value, pred.case_sensitive)) return true;
            if (!val.is_quoted) {
                if (pred.num_value orelse (std.fmt.parseFloat(f64, pred.value) catch null)) |p_num| {
                    if (std.fmt.parseFloat(f64, text) catch null) |v_num| {
                        return v_num == p_num;
                    }
                }
            }
            return false;
        },
        .neq => {
            if (eqStrings(text, pred.value, pred.case_sensitive)) return false;
            if (!val.is_quoted) {
                if (pred.num_value orelse (std.fmt.parseFloat(f64, pred.value) catch null)) |p_num| {
                    if (std.fmt.parseFloat(f64, text) catch null) |v_num| {
                        if (v_num == p_num) return false;
                    }
                }
            }
            return true;
        },
        .contains => return containsString(text, pred.value, pred.case_sensitive),
        .gt_num => {
            const p_num = pred.num_value orelse (std.fmt.parseFloat(f64, pred.value) catch return false);
            const v_num = std.fmt.parseFloat(f64, text) catch return false;
            return v_num > p_num;
        },
        .lt_num => {
            const p_num = pred.num_value orelse (std.fmt.parseFloat(f64, pred.value) catch return false);
            const v_num = std.fmt.parseFloat(f64, text) catch return false;
            return v_num < p_num;
        },
    }
}

pub fn matchesKvPredicates(raw_line: []const u8, predicates: []const KvPredicate) bool {
    if (predicates.len == 0) return true;
    const line = sliceAtLineEnd(raw_line);
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len == 0) return false;

    const json_slice_opt: ?[]const u8 = if (trimmed[0] == '{')
        trimmed
    else if (std.mem.indexOfScalar(u8, trimmed, '{')) |brace| blk: {
        // Handle `<timestamp> <level> {"key": ...}` mixed log lines
        const candidate = trimmed[brace..];
        if (std.mem.indexOfScalar(u8, candidate, ':') != null) break :blk candidate;
        break :blk null;
    } else null;

    for (predicates) |pred| {
        var found: ?ExtractedVal = null;
        if (json_slice_opt) |js| {
            found = extractJsonFieldRaw(js, pred.key);
        }
        if (found == null) {
            if (extractLogfmtFieldRaw(trimmed, pred.key)) |lf_val| {
                found = .{ .raw = lf_val, .is_quoted = false, .is_null = false };
            }
        }
        if (!evalExtractedKv(found, pred)) return false;
    }
    return true;
}

// ============================================================================
// Unit Tests
// ============================================================================

