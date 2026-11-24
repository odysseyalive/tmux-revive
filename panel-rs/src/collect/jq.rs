//! The jq programs scripts/panel.sh (and common.sh's claude_ctx_file) runs over agents' files,
//! each ported to serde_json filter by filter. jq's ways are kept where they show:
//! - a number prints as written (jq 1.7 on keeps a literal's text: 1.50 stays 1.50), and a
//!   sum as a whole number when it is one;
//! - `a // b` takes b for null and false alike;
//! - `.k` of anything but an object or null is an error, and an error ends the program for that
//!   input: with -R and no -n jq goes on to the next line, under -n (reduce, last(inputs)) it
//!   stops for good, printing nothing more;
//! - `@tsv` escapes \ tab newline and return, and refuses objects and arrays;
//! - bytes that aren't UTF-8 are read as U+FFFD.
//!
//! Each returns what jq would print (its lines), which the caller then reads as bash does.

use super::sh::Bytes;
use serde_json::Value as V;

pub type R<T> = Result<T, ()>;

/// A JSON text as jq reads it: bad UTF-8 replaced, then parsed. None: not JSON (jq stops there).
pub fn parse(b: &[u8]) -> Option<V> {
    let s = String::from_utf8_lossy(b);
    serde_json::from_str(&s).ok()
}

/// Every JSON value in a file, in order, as jq reads one file; the bool says it stopped at a
/// parse error.
pub fn parse_all(b: &[u8]) -> (Vec<V>, bool) {
    let s = String::from_utf8_lossy(b);
    let mut out = Vec::new();
    let mut it = serde_json::Deserializer::from_str(&s).into_iter::<V>();
    loop {
        match it.next() {
            Some(Ok(v)) => out.push(v),
            Some(Err(_)) => return (out, true),
            None => return (out, false),
        }
    }
}

/// `fromjson?` of a line read with -R (None: it isn't one JSON value)
pub fn fromjson(line: &[u8]) -> Option<V> {
    parse(line)
}

pub fn truthy(v: &V) -> bool {
    !matches!(v, V::Null | V::Bool(false))
}

static NULL: V = V::Null;

/// `.k`
pub fn idx<'a>(v: &'a V, k: &str) -> R<&'a V> {
    match v {
        V::Object(m) => Ok(m.get(k).unwrap_or(&NULL)),
        V::Null => Ok(&NULL),
        _ => Err(()),
    }
}
/// `.a.b.c`
pub fn path<'a>(v: &'a V, ks: &[&str]) -> R<&'a V> {
    let mut c = v;
    for k in ks {
        c = idx(c, k)?;
    }
    Ok(c)
}
/// `.k?`
pub fn idx_opt<'a>(v: &'a V, k: &str) -> Option<&'a V> {
    idx(v, k).ok()
}

pub fn jtype(v: &V) -> &'static str {
    match v {
        V::Null => "null",
        V::Bool(_) => "boolean",
        V::Number(_) => "number",
        V::String(_) => "string",
        V::Array(_) => "array",
        V::Object(_) => "object",
    }
}

/// A number as jq prints it: a literal as written (its exponent made canonical, 1e3 is 1E+3);
/// one jq worked out, whole when it's whole.
pub fn num_str(n: &serde_json::Number) -> String {
    let s = n.to_string();
    if !s.contains(['e', 'E']) {
        return s;
    }
    // decNumber's form of an exponent: mantissa, E, sign, digits
    let (m, e) = s.split_at(s.find(['e', 'E']).unwrap());
    let e = &e[1..];
    let (sign, d) = match e.strip_prefix('-') {
        Some(d) => ("-", d),
        None => ("+", e.strip_prefix('+').unwrap_or(e)),
    };
    format!("{}E{}{}", m, sign, d.trim_start_matches('0').to_string().chars().next().map(|_| d.trim_start_matches('0')).unwrap_or("0"))
}
pub fn f_str(f: f64) -> String {
    if f.is_finite() && f == f.trunc() && f.abs() < 1e17 {
        format!("{}", f as i64)
    } else if f.is_nan() {
        "null".into()
    } else {
        format!("{}", f)
    }
}
pub fn as_f(v: &V) -> Option<f64> {
    match v {
        V::Number(n) => n.as_f64(),
        _ => None,
    }
}

/// `tostring`
pub fn tostring(v: &V) -> String {
    match v {
        V::String(s) => s.clone(),
        V::Number(n) => num_str(n),
        _ => compact(v),
    }
}
/// jq -c's text of a value
pub fn compact(v: &V) -> String {
    match v {
        V::Null => "null".into(),
        V::Bool(b) => b.to_string(),
        V::Number(n) => num_str(n),
        V::String(_) => serde_json::to_string(v).unwrap_or_default(),
        V::Array(a) => format!("[{}]", a.iter().map(compact).collect::<Vec<_>>().join(",")),
        V::Object(m) => format!("{{{}}}", m.iter().map(|(k, x)| format!("{}:{}", serde_json::to_string(k).unwrap_or_default(), compact(x))).collect::<Vec<_>>().join(",")),
    }
}
/// `"\(x)"`: a string as it is, anything else as tostring
pub fn interp(v: &V) -> String {
    tostring(v)
}

/// `@tsv` of an array
pub fn tsv(a: &[V]) -> R<String> {
    let mut out = Vec::new();
    for v in a {
        out.push(match v {
            V::String(s) => s.replace('\\', "\\\\").replace('\t', "\\t").replace('\n', "\\n").replace('\r', "\\r"),
            V::Number(n) => num_str(n),
            V::Bool(b) => b.to_string(),
            V::Null => String::new(),
            _ => return Err(()),
        });
    }
    Ok(out.join("\t"))
}

/// `join(SEP)`: null as nothing, numbers and booleans as text, anything else an error
pub fn join(a: &[V], sep: &str) -> R<String> {
    let mut out = Vec::new();
    for v in a {
        out.push(match v {
            V::String(s) => s.clone(),
            V::Number(n) => num_str(n),
            V::Bool(b) => b.to_string(),
            V::Null => String::new(),
            _ => return Err(()),
        });
    }
    Ok(out.join(sep))
}

/// `gsub("[\u0000-\u001f]"; REP)`
pub fn gsub_ctrl(s: &str, rep: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        if (c as u32) < 0x20 {
            o.push_str(rep);
        } else {
            o.push(c);
        }
    }
    o
}

/// `a // b` where a yields one value
pub fn alt<'a>(a: &'a V, b: &'a V) -> &'a V {
    if truthy(a) {
        a
    } else {
        b
    }
}

/// `fromdateiso8601`: exactly %Y-%m-%dT%H:%M:%SZ, as jq's strptime takes it
pub fn fromdateiso8601(s: &str) -> Option<i64> {
    let m = crate::compat::re("^([0-9]{1,4})-([0-9]{1,2})-([0-9]{1,2})T([0-9]{1,2}):([0-9]{1,2}):([0-9]{1,2})Z$").matches(s.as_bytes())?;
    let n = |b: &[u8]| -> i64 { std::str::from_utf8(b).unwrap().parse().unwrap() };
    let (y, mo, d, h, mi, se) = (n(&m[1]), n(&m[2]), n(&m[3]), n(&m[4]), n(&m[5]), n(&m[6]));
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
        return None;
    }
    // days from the civil date (the same sum iso_epoch does)
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let doy = (153 * (if mo > 2 { mo - 3 } else { mo + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some((era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se)
}

/// `sub("\\.[0-9]+"; "")`: the first `.digits` taken out
pub fn sub_frac(s: &str) -> String {
    let b = s.as_bytes();
    for i in 0..b.len() {
        if b[i] == b'.' && i + 1 < b.len() && b[i + 1].is_ascii_digit() {
            let mut j = i + 1;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            return format!("{}{}", &s[..i], &s[j..]);
        }
    }
    s.to_string()
}

/// jq string `length`: its characters
pub fn slen(s: &str) -> usize {
    s.chars().count()
}

// ------------------------------------------------------------------ the programs

/// agents_look's and claude_look's, of one record:
/// `[.status // "", .sessionId // "", (.statusUpdatedAt // "" | tostring), (.startedAt // "" | tostring)] | @tsv`
pub fn record_tsv(v: &V) -> R<String> {
    let e = V::String(String::new());
    let st = alt(idx(v, "status")?, &e).clone();
    let sid = alt(idx(v, "sessionId")?, &e).clone();
    let su = V::String(tostring(alt(idx(v, "statusUpdatedAt")?, &e)));
    let sa = V::String(tostring(alt(idx(v, "startedAt")?, &e)));
    tsv(&[st, sid, su, sa])
}

/// `jq -r PROG FILE...` over records, each line prefixed by its file (input_filename) when
/// NAMED: what it prints before it stops (at a record it can't parse; a record it can't run on
/// is an error, which ends it too).
pub fn records_tsv(files: &[Bytes], named: bool) -> Vec<Bytes> {
    let mut out = Vec::new();
    for f in files {
        let data = std::fs::read(super::sh::os(f)).unwrap_or_default();
        let (vals, bad) = parse_all(&data);
        for v in &vals {
            match record_tsv(v) {
                Ok(l) => {
                    let mut line = Vec::new();
                    if named {
                        line.extend_from_slice(&tsv(&[V::String(String::from_utf8_lossy(f).into_owned())]).unwrap_or_default().into_bytes());
                        line.push(b'\t');
                    }
                    line.extend_from_slice(l.as_bytes());
                    out.push(line);
                }
                // jq goes on to the next value after a runtime error
                Err(()) => continue,
            }
        }
        if bad {
            return out;
        }
    }
    out
}

/// ctx_left's `jq -r '.sessionId // empty' RECORD`: its lines
pub fn session_id(data: &[u8]) -> Vec<String> {
    let (vals, _) = parse_all(data);
    let mut out = Vec::new();
    for v in vals {
        if let Ok(s) = idx(&v, "sessionId") {
            if truthy(s) {
                out.push(tostring(s));
            }
        }
    }
    out
}

/// acct_read's `[(first(F1) // ""), (first(F2) // "")] | map(tostring | gsub(ctrl; "")) |
/// join("\u001f")` over each value of the file; the filters as their own functions.
pub fn acct(data: &[u8], f1: fn(&V) -> R<Option<V>>, f2: fn(&V) -> R<Option<V>>) -> Vec<String> {
    let (vals, _) = parse_all(data);
    let mut out = Vec::new();
    for v in vals {
        let r = (|| -> R<String> {
            let e = V::String(String::new());
            let a = f1(&v)?.filter(truthy).unwrap_or(e.clone());
            let b = f2(&v)?.filter(truthy).unwrap_or(e);
            Ok(format!("{}\u{1f}{}", gsub_ctrl(&tostring(&a), ""), gsub_ctrl(&tostring(&b), "")))
        })();
        if let Ok(l) = r {
            out.push(l);
        }
    }
    out
}

/// CL_ACCT_JQ: `.oauthAccount.emailAddress // empty | strings` (its first output)
pub fn cl_acct(v: &V) -> R<Option<V>> {
    let x = path(v, &["oauthAccount", "emailAddress"])?;
    Ok(if truthy(x) && x.is_string() { Some(x.clone()) } else { None })
}
/// CL_PLAN_JQ: `.oauthAccount // empty | [.planDisplayName, .organizationRateLimitTier,
/// .userRateLimitTier, .seatTier, .hasExtraUsageEnabled] | map(. // "-" | tostring) | join("/")`
pub fn cl_plan(v: &V) -> R<Option<V>> {
    let o = idx(v, "oauthAccount")?;
    if !truthy(o) {
        return Ok(None);
    }
    let mut parts = Vec::new();
    for k in ["planDisplayName", "organizationRateLimitTier", "userRateLimitTier", "seatTier", "hasExtraUsageEnabled"] {
        let x = idx(o, k)?;
        parts.push(if truthy(x) { tostring(x) } else { "-".into() });
    }
    Ok(Some(V::String(parts.join("/"))))
}
/// CX_TOKEN_JQ: the id_token's middle part, base64url made base64 and padded, decoded, as JSON
fn cx_token(v: &V) -> R<Option<V>> {
    let t = path(v, &["tokens", "id_token"])?;
    if !truthy(t) {
        return Ok(None);
    }
    let V::String(t) = t else { return Ok(None) };
    let parts: Vec<&str> = t.split('.').collect();
    let Some(mid) = parts.get(1) else { return Ok(None) };
    // `split(".")[1] // empty`: "" is truthy, so goes on
    let mut s = mid.replace('-', "+").replace('_', "/");
    let pad = (4 - slen(&s) % 4) % 4;
    s.push_str(&"=".repeat(pad));
    let bytes = b64d(&s)?;
    Ok(parse(&bytes))
}
/// `... | .email // empty | strings`
pub fn cx_email(v: &V) -> R<Option<V>> {
    let Some(t) = cx_token(v)? else { return Ok(None) };
    let x = idx(&t, "email")?;
    Ok(if truthy(x) && x.is_string() { Some(x.clone()) } else { None })
}
/// CX_PLAN_JQ: `... | ."https://api.openai.com/auth".chatgpt_plan_type // empty | strings`
pub fn cx_plan(v: &V) -> R<Option<V>> {
    let Some(t) = cx_token(v)? else { return Ok(None) };
    let x = path(&t, &["https://api.openai.com/auth", "chatgpt_plan_type"])?;
    Ok(if truthy(x) && x.is_string() { Some(x.clone()) } else { None })
}

/// jq's @base64d: standard alphabet, padding optional, stopping at the first byte outside it
fn b64d(s: &str) -> R<Bytes> {
    let mut out = Vec::new();
    let mut acc: u32 = 0;
    let mut n = 0;
    for c in s.bytes() {
        let d = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => return Err(()),
        } as u32;
        acc = acc << 6 | d;
        n += 1;
        if n == 4 {
            out.extend_from_slice(&[(acc >> 16) as u8, (acc >> 8) as u8, acc as u8]);
            acc = 0;
            n = 0;
        }
    }
    match n {
        2 => out.push((acc >> 4) as u8),
        3 => out.extend_from_slice(&[(acc >> 10) as u8, (acc >> 2) as u8]),
        1 => return Err(()),
        _ => {}
    }
    Ok(out)
}

/// claude_turn_from's, of one line: `.message.content | if type == "string" then . else ([.[]? |
/// select(.type == "text") | .text] | first // "") end | .[0:16]` -> what -r prints (None: error)
pub fn turn_text(line: &[u8]) -> Option<String> {
    let v = parse(line)?;
    let c = path(&v, &["message", "content"]).ok()?;
    let t: V = if let V::String(_) = c {
        c.clone()
    } else {
        let items: Vec<&V> = match c {
            V::Array(a) => a.iter().collect(),
            V::Object(m) => m.values().collect(),
            _ => Vec::new(),
        };
        let mut texts = Vec::new();
        for it in items {
            let ty = idx(it, "type").ok()?;
            if ty == "text" {
                texts.push(idx(it, "text").ok()?.clone());
            }
        }
        let f = texts.into_iter().next().unwrap_or(V::Null);
        if truthy(&f) {
            f
        } else {
            V::String(String::new())
        }
    };
    match t {
        V::String(s) => Some(s.chars().take(16).collect()),
        V::Null => Some("null".into()),
        V::Array(a) => Some(compact(&V::Array(a.into_iter().take(16).collect()))),
        _ => None,
    }
}

/// codex_ctx_file's, line by line: `fromjson? | .payload | select(.type == "token_count" and
/// .info) | "\(.info.last_token_usage.total_tokens) \(.info.model_context_window)"`
pub fn codex_tokens(line: &[u8]) -> Option<String> {
    let v = fromjson(line)?;
    let p = idx(&v, "payload").ok()?;
    let ty = idx(p, "type").ok()?;
    if ty != "token_count" {
        return None;
    }
    let info = idx(p, "info").ok()?;
    if !truthy(info) {
        return None;
    }
    let t = path(info, &["last_token_usage", "total_tokens"]).ok()?;
    let w = idx(info, "model_context_window").ok()?;
    Some(format!("{} {}", interp(t), interp(w)))
}

/// claude_ctx_file's, line by line (-R, no -n: an error skips the line): "a USED MODEL" for a
/// main-conversation turn, "c POST" for a compaction
pub fn claude_usage(line: &[u8]) -> Option<String> {
    let v = fromjson(line)?;
    let sc = idx(&v, "isSidechain").ok()?;
    if truthy(sc) {
        return None;
    }
    let ty = idx(&v, "type").ok()?;
    let msg = idx(&v, "message").ok()?;
    let a = ty == "assistant" && {
        let u = idx(msg, "usage").ok()?;
        truthy(u) && idx(msg, "model").ok()? != "<synthetic>"
    };
    if a {
        let u = idx(msg, "usage").ok()?;
        let get = |k: &str| -> Option<V> {
            let x = idx(u, k).ok()?;
            Some(if truthy(x) { x.clone() } else { V::from(0) })
        };
        let (x, y, z) = (get("input_tokens")?, get("cache_read_input_tokens")?, get("cache_creation_input_tokens")?);
        let sum = add(&add(&x, &y)?, &z)?;
        return Some(format!("a {} {}", interp(&sum), interp(idx(msg, "model").ok()?)));
    }
    if ty == "system" && idx(&v, "subtype").ok()? == "compact_boundary" {
        let pt = path(&v, &["compactMetadata", "postTokens"]).ok()?;
        if jtype(pt) == "number" {
            return Some(format!("c {}", interp(pt)));
        }
    }
    None
}

/// jq's `+` of two values that came from `// 0` (numbers, or something else: an error, except
/// strings, arrays and objects with their own kind)
fn add(a: &V, b: &V) -> Option<V> {
    match (a, b) {
        (V::Null, x) | (x, V::Null) => Some(x.clone()),
        (V::Number(_), V::Number(_)) => {
            let s = as_f(a)? + as_f(b)?;
            Some(num_val(s))
        }
        (V::String(x), V::String(y)) => Some(V::String(format!("{}{}", x, y))),
        (V::Array(x), V::Array(y)) => Some(V::Array(x.iter().chain(y.iter()).cloned().collect())),
        _ => None,
    }
}
/// A number jq worked out (printed whole when whole)
fn num_val(f: f64) -> V {
    serde_json::from_str::<V>(&f_str(f)).unwrap_or(V::Null)
}

/// codex_wait_at's `reduce (inputs | fromjson? | select(.payload | type == "object")) as $e ({};
/// ...) | [.[]] | last // empty | sub("\\.[0-9]+"; "") | fromdateiso8601? // empty` over the
/// grep'd lines: what it prints (the epoch), or nothing (an error anywhere ends it with nothing)
pub fn codex_wait(lines: &[&[u8]]) -> Option<String> {
    // an object keeping its keys in the order they were set, as jq prints them
    let mut acc: Vec<(String, V)> = Vec::new();
    for l in lines {
        let Some(e) = fromjson(l) else { continue };
        let p = idx(&e, "payload").ok()?;
        if jtype(p) != "object" {
            continue;
        }
        let ty = idx(p, "type").ok()?;
        let name = idx(p, "name").ok()?;
        let key = |p: &V| -> Option<String> {
            let c = idx(p, "call_id").ok()?;
            match alt(c, &V::Null) {
                V::Null => Some(String::new()),
                V::String(s) => Some(s.clone()),
                _ => None,
            }
        };
        if ty == "function_call" && (name == "wait_agent" || name == "wait") {
            let k = key(p)?;
            let ts = idx(&e, "timestamp").ok()?;
            let ts = if truthy(ts) { ts.clone() } else { V::String(String::new()) };
            match acc.iter_mut().find(|(kk, _)| *kk == k) {
                Some(x) => x.1 = ts,
                None => acc.push((k, ts)),
            }
        } else if ty == "function_call_output" {
            let k = key(p)?;
            acc.retain(|(kk, _)| *kk != k);
        } else if ty == "task_complete" || ty == "turn_aborted" {
            acc.clear();
        }
    }
    let last = acc.last().map(|x| x.1.clone()).unwrap_or(V::Null);
    if !truthy(&last) {
        return None;
    }
    let V::String(s) = last else { return None };
    let s = sub_frac(&s);
    fromdateiso8601(&s).map(|n| n.to_string())
}

/// codex_meta's, of one first line: `(fromjson? // {}) | (.payload // {}) | [(if
/// .thread_source == "subagent" or (.source | type == "object" and has("subagent")) then "-"
/// else .cwd // "" | tostring end), ((.timestamp // "") | tostring | sub("\\.[0-9]+"; "") |
/// (fromdateiso8601? // ""))] | @tsv`. None: an error (no line out, so the pairs shift).
pub fn codex_meta(line: &[u8]) -> Option<String> {
    let empty = V::Object(Default::default());
    let v = fromjson(line).filter(truthy).unwrap_or(empty.clone());
    let p0 = idx(&v, "payload").ok()?;
    let p = if truthy(p0) { p0.clone() } else { empty };
    let ts_src = idx(&p, "thread_source").ok()?;
    let sub = ts_src == "subagent" || {
        let s = idx(&p, "source").ok()?;
        jtype(s) == "object" && s.as_object().is_some_and(|m| m.contains_key("subagent"))
    };
    let a = if sub {
        "-".to_string()
    } else {
        let c = idx(&p, "cwd").ok()?;
        if truthy(c) {
            tostring(c)
        } else {
            String::new()
        }
    };
    let t = idx(&p, "timestamp").ok()?;
    let t = sub_frac(&if truthy(t) { tostring(t) } else { String::new() });
    let b = match fromdateiso8601(&t) {
        Some(n) => V::from(n),
        None => V::String(String::new()),
    };
    tsv(&[V::String(a), b]).ok()
}

/// claude_limit_file's -n program over the grep'd lines: "AT\x1fTEXT" when the last turn ended
/// at a usage limit, else nothing
pub fn claude_limit(lines: &[&[u8]]) -> Option<String> {
    let lead = crate::compat::Ere::new(b"^[[:space:]]*<(command-|local-command-)", false)?;
    let lim = crate::compat::Ere::new("^(You.ve hit your|You.ve reached your|You.re out of (usage|extra usage)|Your org is out of usage|Claude AI usage limit reached)".as_bytes(), true)?;
    let mut last: Option<V> = None;
    for l in lines {
        let Some(v) = fromjson(l) else { continue };
        if jtype(&v) != "object" {
            continue;
        }
        let ty = idx(&v, "type").ok()?;
        if !(ty == "user" || ty == "assistant") {
            continue;
        }
        if idx(&v, "isSidechain").ok()? == &V::Bool(true) || idx(&v, "isMeta").ok()? == &V::Bool(true) {
            continue;
        }
        let c = path(&v, &["message", "content"]).ok()?;
        let keep = if jtype(c) != "string" {
            true
        } else {
            !lead.is_match(c.as_str().unwrap().as_bytes())
        };
        if keep {
            last = Some(v);
        }
    }
    let v = last?;
    if idx(&v, "type").ok()? != "assistant" || idx(&v, "isApiErrorMessage").ok()? != &V::Bool(true) {
        return None;
    }
    let c = path(&v, &["message", "content"]).ok()?;
    let items: Vec<&V> = match c {
        V::Array(a) => a.iter().collect(),
        V::Object(m) => m.values().collect(),
        _ => Vec::new(),
    };
    let mut texts = Vec::new();
    for it in items {
        if idx(it, "type").ok()? == "text" {
            texts.push(idx(it, "text").ok()?.clone());
        }
    }
    let t = join(&texts, " ").ok()?;
    if !lim.is_match(t.as_bytes()) {
        return None;
    }
    let at = idx(&v, "timestamp").ok()?;
    let at = if truthy(at) { at.clone() } else { V::String(String::new()) };
    join(&[at, V::String(gsub_ctrl(&t, " "))], "\u{1f}").ok()
}

/// codex_limit_file's reduce over the grep'd lines: "AT\x1fRESETS\x1fPLAN\x1fTEXT" or nothing
pub fn codex_limit(lines: &[&[u8]]) -> Option<String> {
    let ul = crate::compat::Ere::new(b"usage_limit", false)?;
    let ulim = crate::compat::Ere::new(b"usage limit", true)?;
    let (mut rl, mut pl, mut lim) = (V::Null, V::Null, V::Null);
    for l in lines {
        let Some(e) = fromjson(l) else { continue };
        if jtype(&e) != "object" {
            continue;
        }
        let p = idx(&e, "payload").ok()?;
        if jtype(p) != "object" {
            continue;
        }
        let ty = idx(p, "type").ok()?;
        let rls = idx(p, "rate_limits").ok()?;
        if ty == "token_count" && jtype(rls) == "object" {
            let pt = idx(rls, "plan_type").ok()?;
            if jtype(pt) == "string" {
                pl = pt.clone();
            }
            let pr = idx(rls, "primary").ok()?;
            let se = idx(rls, "secondary").ok()?;
            if jtype(pr) == "object" || jtype(se) == "object" {
                rl = rls.clone();
            }
        } else if ty == "task_started" || ty == "turn_aborted" {
            lim = V::Null;
        } else if ty == "task_complete" && jtype(idx(p, "error").ok()?) == "object" {
            let err = idx(p, "error").ok()?;
            let info = idx(err, "codex_error_info").ok()?;
            lim = if ul.is_match(tostring(info).as_bytes()) {
                let m = idx(err, "message").ok()?;
                let m = if truthy(m) { m.clone() } else { V::String(String::new()) };
                obj(&[("at", idx(&e, "timestamp").ok()?.clone()), ("t", m), ("rl", rl.clone()), ("pl", pl.clone())])
            } else {
                V::Null
            };
        } else if ty == "error" && {
            let m = idx(p, "message").ok()?;
            let m = if truthy(m) { m.clone() } else { V::String(String::new()) };
            ulim.is_match(tostring(&m).as_bytes())
        } {
            lim = obj(&[("at", idx(&e, "timestamp").ok()?.clone()), ("t", idx(p, "message").ok()?.clone()), ("rl", rl.clone()), ("pl", pl.clone())]);
        }
    }
    if !truthy(&lim) {
        return None;
    }
    let at = idx(&lim, "at").ok()?;
    let at = if truthy(at) { at.clone() } else { V::String(String::new()) };
    let lrl = idx(&lim, "rl").ok()?;
    let mut rs = Vec::new();
    for k in ["primary", "secondary"] {
        // .rl.primary.resets_at?
        let x = idx(lrl, k).ok().and_then(|o| idx(o, "resets_at").ok()).cloned().unwrap_or(V::Null);
        if let Some(f) = as_f(&x) {
            rs.push(V::String(f_str(f.floor())));
        }
    }
    let rs = V::String(join(&rs, " ").ok()?);
    let lpl = idx(&lim, "pl").ok()?;
    let lpl = if truthy(lpl) { lpl.clone() } else { V::String(String::new()) };
    let t = idx(&lim, "t").ok()?.clone();
    let parts: Vec<V> = [at, rs, lpl, t].iter().map(|x| V::String(gsub_ctrl(&tostring(x), " "))).collect();
    join(&parts, "\u{1f}").ok()
}

fn obj(kv: &[(&str, V)]) -> V {
    let mut m = serde_json::Map::new();
    for (k, v) in kv {
        m.insert(k.to_string(), v.clone());
    }
    V::Object(m)
}

/// links_saves's `[.saved_at, .reason] | @tsv` of state.json: its first line
pub fn saved(data: &[u8]) -> Option<String> {
    let (vals, _) = parse_all(data);
    let v = vals.first()?;
    tsv(&[idx(v, "saved_at").ok()?.clone(), idx(v, "reason").ok()?.clone()]).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Run jq itself (skipped where there's none)
    fn jq(args: &[&str], input: &[u8]) -> Option<Vec<u8>> {
        use std::io::Write;
        let mut c = std::process::Command::new("jq").args(args).stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::null()).spawn().ok()?;
        c.stdin.take().unwrap().write_all(input).ok()?;
        Some(c.wait_with_output().ok()?.stdout)
    }
    fn lines_of(o: &[u8]) -> Vec<String> {
        String::from_utf8_lossy(o).lines().map(String::from).collect()
    }

    const REC: &str = r#"[.status // "", .sessionId // "", (.statusUpdatedAt // "" | tostring), (.startedAt // "" | tostring)] | @tsv"#;

    #[test]
    fn records_as_jq() {
        let cases = [
            r#"{"status":"idle","sessionId":"s-1","statusUpdatedAt":1763000000123,"startedAt":1762000000000}"#,
            r#"{"status":"","sessionId":"a\tb","statusUpdatedAt":"x","startedAt":null}"#,
            r#"{"status":false,"sessionId":1.50,"statusUpdatedAt":1e3}"#,
            r#"{"status":"busy","sessionId":"x\\y\nz"}"#,
            r#"{}"#,
            r#"[1]"#,
            r#"{"status":{"a":1}}"#,
            r#"{"status":true,"sessionId":-0}"#,
        ];
        for c in cases {
            let Some(theirs) = jq(&["-r", REC], c.as_bytes()) else { return };
            let ours: Vec<String> = record_tsv(&parse(c.as_bytes()).unwrap()).into_iter().collect();
            assert_eq!(ours, lines_of(&theirs), "{}", c);
        }
    }

    fn acct_prog(f1: &str, f2: &str) -> String {
        format!("[(first({}) // \"\"), (first({}) // \"\")] | map(tostring | gsub(\"[\\u0000-\\u001f]\"; \"\")) | join(\"\\u001f\")", f1, f2)
    }
    const CL_PLAN_JQ: &str = r#".oauthAccount // empty | [.planDisplayName, .organizationRateLimitTier, .userRateLimitTier, .seatTier, .hasExtraUsageEnabled] | map(. // "-" | tostring) | join("/")"#;
    const CX_TOKEN_JQ: &str = r#".tokens.id_token // empty | strings | split(".")[1] // empty
		| gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson?"#;
    const CL_ACCT_JQ: &str = r#".oauthAccount.emailAddress // empty | strings"#;

    #[test]
    fn accounts_as_jq() {
        let b64u = |s: &str| -> String {
            let o = std::process::Command::new("base64").arg("-w0").stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).spawn();
            let Ok(mut o) = o else { return String::new() };
            use std::io::Write;
            o.stdin.take().unwrap().write_all(s.as_bytes()).unwrap();
            String::from_utf8(o.wait_with_output().unwrap().stdout).unwrap().replace('+', "-").replace('/', "_").replace('=', "")
        };
        let tok = |p: &str| format!(r#"{{"tokens":{{"id_token":"{}.{}.sig"}}}}"#, b64u(r#"{"alg":"RS256"}"#), b64u(p));
        let cl = [
            r#"{"oauthAccount":{"emailAddress":"me.here+x@example.com","planDisplayName":"Max","organizationRateLimitTier":"t1","hasExtraUsageEnabled":false}}"#,
            r#"{"oauthAccount":{"emailAddress":7,"seatTier":1.5,"hasExtraUsageEnabled":true}}"#,
            r#"{"oauthAccount":"str"}"#,
            r#"{"oauthAccount":{"emailAddress":"a\u0001b@c","planDisplayName":"P\nQ"}}"#,
            r#"{}"#,
            r#"[]"#,
        ];
        for c in cl {
            let Some(theirs) = jq(&["-r", &acct_prog(CL_ACCT_JQ, CL_PLAN_JQ)], c.as_bytes()) else { return };
            assert_eq!(acct(c.as_bytes(), cl_acct, cl_plan), lines_of(&theirs), "{}", c);
        }
        let cx_email_jq = format!("{} | .email // empty | strings", CX_TOKEN_JQ);
        let cx_plan_jq = format!("{} | .\"https://api.openai.com/auth\".chatgpt_plan_type // empty | strings", CX_TOKEN_JQ);
        let cx = [
            tok(r#"{"email":"codex.fixture@example.com","https://api.openai.com/auth":{"chatgpt_plan_type":"plus"}}"#),
            tok(r#"{"email":"a@b"}"#),
            tok(r#"{"emai"#),
            tok("x"),
            r#"{"tokens":{"id_token":"nodots"}}"#.to_string(),
            r#"{"tokens":{"id_token":"a.b!c.d"}}"#.to_string(),
            r#"{"tokens":{"id_token":5}}"#.to_string(),
        ];
        for c in &cx {
            let Some(theirs) = jq(&["-r", &acct_prog(&cx_email_jq, &cx_plan_jq)], c.as_bytes()) else { return };
            assert_eq!(acct(c.as_bytes(), cx_email, cx_plan), lines_of(&theirs), "{}", c);
        }
    }

    const USAGE_JQ: &str = r#"fromjson? | select(.isSidechain | not)
			| if .type == "assistant" and .message.usage and .message.model != "<synthetic>" then .message
				| "a \((.usage.input_tokens // 0) + (.usage.cache_read_input_tokens // 0)
					+ (.usage.cache_creation_input_tokens // 0)) \(.model)"
			elif .type == "system" and .subtype == "compact_boundary"
				and (.compactMetadata.postTokens | type) == "number" then "c \(.compactMetadata.postTokens)"
			else empty end"#;

    #[test]
    fn usage_as_jq() {
        let t = concat!(
            r#"{"type":"assistant","message":{"model":"claude-haiku-4-5","usage":{"input_tokens":5,"cache_read_input_tokens":40000,"cache_creation_input_tokens":5000}}}"#, "\n",
            r#"{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":190000}}}"#, "\n",
            r#"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0}}}"#, "\n",
            r#"{"type":"user","message":{"content":"the word \"usage\" in a message"}}"#, "\n",
            r#"{"isSidechain":false,"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":100000}}"#, "\n",
            r#"{"type":"assistant","message":{"usage":{"input_tokens":1.5}}}"#, "\n",
            r#"{"type":"assistant","message":{"model":"m","usage":{"input_tokens":"5"}}}"#, "\n",
            r#""a string""#, "\n",
            r#"{"type":"assistant","message":"str"}"#, "\n",
            "{cut in ha\n",
            r#"{"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":"9"}}"#, "\n",
        );
        let Some(theirs) = jq(&["-Rr", USAGE_JQ], t.as_bytes()) else { return };
        let ours: Vec<String> = t.lines().filter_map(|l| claude_usage(l.as_bytes())).collect();
        assert_eq!(ours, lines_of(&theirs));
    }

    #[test]
    fn codex_lines_as_jq() {
        let t = concat!(
            r#"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200000},"model_context_window":250000}}}"#, "\n",
            r#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#, "\n",
            r#"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#, "\n",
            r#"{"payload":"x"}"#, "\n",
            r#"[1]"#, "\n",
        );
        let prog = r#"fromjson? | .payload | select(.type == "token_count" and .info) | "\(.info.last_token_usage.total_tokens) \(.info.model_context_window)""#;
        let Some(theirs) = jq(&["-Rr", prog], t.as_bytes()) else { return };
        let ours: Vec<String> = t.lines().filter_map(|l| codex_tokens(l.as_bytes())).collect();
        assert_eq!(ours, lines_of(&theirs));
        let meta = r#"(fromjson? // {}) | (.payload // {}) | [(if .thread_source == "subagent" or (.source | type == "object" and has("subagent")) then "-" else .cwd // "" | tostring end),
			((.timestamp // "") | tostring | sub("\\.[0-9]+"; "") | (fromdateiso8601? // ""))] | @tsv"#;
        let m = concat!(
            r#"{"type":"session_meta","payload":{"id":"a","timestamp":"2026-01-02T00:00:00.123Z","cwd":"/w/x","originator":"codex-tui"}}"#, "\n",
            r#"{"type":"session_meta","payload":{"id":"k","timestamp":"2026-01-02T00:00:01.5Z","cwd":"/w","source":{"subagent":{}},"thread_source":"subagent"}}"#, "\n",
            r#"{"payload":{"timestamp":17,"cwd":3}}"#, "\n",
            r#"{"payload":{"timestamp":"bad","cwd":"/a\tb"}}"#, "\n",
            r#"{"payload":"str"}"#, "\n",
            "not json\n",
            "\n",
            r#"{"payload":{"source":"x","timestamp":"2026-11-23T10:00:00Z"}}"#, "\n",
        );
        let Some(theirs) = jq(&["-Rr", meta], m.as_bytes()) else { return };
        let ours: Vec<String> = m.lines().filter_map(|l| codex_meta(l.as_bytes())).collect();
        assert_eq!(ours, lines_of(&theirs));
    }

    #[test]
    fn waits_and_limits_as_jq() {
        crate::compat::tests::setup();
        let wait = r#"reduce (inputs | fromjson? | select(.payload | type == "object")) as $e ({};
			$e.payload as $p
			| if $p.type == "function_call" and ($p.name == "wait_agent" or $p.name == "wait") then .[$p.call_id // ""] = ($e.timestamp // "")
			elif $p.type == "function_call_output" then del(.[$p.call_id // ""])
			elif $p.type == "task_complete" or $p.type == "turn_aborted" then {}
			else . end)
			| [.[]] | last // empty | sub("\\.[0-9]+"; "") | fromdateiso8601? // empty"#;
        let cases = [
            concat!(
                r#"{"timestamp":"2026-01-03T00:00:00.123Z","type":"response_item","payload":{"type":"function_call","name":"wait_agent","call_id":"c1"}}"#, "\n",
                r#"{"timestamp":"2026-01-03T00:00:05.000Z","type":"response_item","payload":{"type":"function_call","name":"wait","call_id":"c2"}}"#, "\n",
            ),
            concat!(
                r#"{"timestamp":"2026-01-03T00:00:00.123Z","payload":{"type":"function_call","name":"wait_agent","call_id":"c1"}}"#, "\n",
                r#"{"payload":{"type":"function_call_output","call_id":"c1"}}"#, "\n",
            ),
            concat!(
                r#"{"timestamp":"2026-01-03T00:00:00.123Z","payload":{"type":"function_call","name":"wait_agent","call_id":"c1"}}"#, "\n",
                r#"{"payload":{"type":"turn_aborted"}}"#, "\n",
                r#"{"timestamp":"2026-01-03T00:01:00Z","payload":{"type":"function_call","name":"wait_agent"}}"#, "\n",
            ),
            concat!(r#""str""#, "\n", r#"{"timestamp":"2026-01-03T00:00:00Z","payload":{"type":"function_call","name":"wait","call_id":"c"}}"#, "\n"),
            concat!(r#"{"timestamp":"x","payload":{"type":"function_call","name":"wait","call_id":"c"}}"#, "\n"),
        ];
        for c in cases {
            let Some(theirs) = jq(&["-Rnr", wait], c.as_bytes()) else { return };
            let ls: Vec<&[u8]> = c.lines().map(|l| l.as_bytes()).collect();
            let ours: Vec<String> = codex_wait(&ls).into_iter().collect();
            assert_eq!(ours, lines_of(&theirs), "{}", c);
        }
        let cl = r#"last(inputs | fromjson? | select(type == "object" and (.type == "user" or .type == "assistant") and .isSidechain != true and .isMeta != true
				and ((.message.content | type) != "string" or (.message.content | test("^\\s*<(command-|local-command-)") | not))))
			| select(.type == "assistant" and .isApiErrorMessage == true)
			| ([.message.content[]? | select(.type == "text") | .text] | join(" ")) as $t
			| select($t | test("^(You.ve hit your|You.ve reached your|You.re out of (usage|extra usage)|Your org is out of usage|Claude AI usage limit reached)"; "i"))
			| [(.timestamp // ""), ($t | gsub("[\u0000-\u001f]"; " "))] | join("\u001f")"#;
        let cases = [
            concat!(r#"{"type":"assistant","timestamp":"2026-11-23T21:00:00.000Z","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You've hit your session limit · resets 10pm (Europe/Paris)"}]}}"#, "\n"),
            concat!(
                r#"{"type":"assistant","timestamp":"2026-11-23T21:00:00.000Z","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"you\u2019re out of usage\nnow"}]}}"#, "\n",
                r#"{"type":"user","message":{"content":"  <command-name>/usage"}}"#, "\n",
            ),
            concat!(
                r#"{"type":"assistant","timestamp":"t","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Claude AI usage limit reached|1763000000"}]}}"#, "\n",
                r#"{"type":"user","message":{"content":"go on"}}"#, "\n",
            ),
            concat!(r#"{"type":"assistant","timestamp":5,"isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"You've reached your limit"}]}}"#, "\n"),
            concat!(r#"{"type":"assistant","message":"str"}"#, "\n"),
        ];
        for c in cases {
            let Some(theirs) = jq(&["-Rnr", cl], c.as_bytes()) else { return };
            let ls: Vec<&[u8]> = c.lines().map(|l| l.as_bytes()).collect();
            let ours: Vec<String> = claude_limit(&ls).into_iter().collect();
            assert_eq!(ours, lines_of(&theirs), "{}", c);
        }
        let cx = r#"reduce (inputs | fromjson? | select(type == "object" and (.payload | type == "object"))) as $e ({rl: null, pl: null, lim: null};
			$e.payload as $p
			| if $p.type == "token_count" and ($p.rate_limits | type == "object") then
				(if ($p.rate_limits.plan_type | type == "string") then .pl = $p.rate_limits.plan_type else . end)
				| (if ([$p.rate_limits.primary, $p.rate_limits.secondary] | map(objects) | length) > 0 then .rl = $p.rate_limits else . end)
			elif $p.type == "task_started" or $p.type == "turn_aborted" then .lim = null
			elif $p.type == "task_complete" and ($p.error | type == "object") then
				.lim = (if ($p.error.codex_error_info | tostring | test("usage_limit")) then {at: $e.timestamp, t: ($p.error.message // ""), rl: .rl, pl: .pl} else null end)
			elif $p.type == "error" and ($p.message // "" | tostring | test("usage limit"; "i")) then .lim = {at: $e.timestamp, t: $p.message, rl: .rl, pl: .pl}
			else . end)
			| .lim // empty
			| [(.at // ""), ([.rl.primary.resets_at?, .rl.secondary.resets_at?] | map(numbers | floor | tostring) | join(" ")), (.pl // ""), .t]
			| map(tostring | gsub("[\u0000-\u001f]"; " ")) | join("\u001f")"#;
        let cases = [
            concat!(
                r#"{"timestamp":"2026-11-23T21:00:00.000Z","payload":{"type":"token_count","rate_limits":{"plan_type":"plus","primary":{"resets_at":1795000123.7},"secondary":{"resets_at":1795600000}}}}"#, "\n",
                r#"{"timestamp":"2026-11-23T21:00:01.000Z","payload":{"type":"task_complete","error":{"codex_error_info":"usage_limit_exceeded","message":"You've hit your usage limit. Try again at 10:10 PM."}}}"#, "\n",
            ),
            concat!(
                r#"{"timestamp":"2026-11-23T21:00:01.000Z","payload":{"type":"error","message":"Usage Limit reached\tsoon"}}"#, "\n",
                r#"{"payload":{"type":"task_started"}}"#, "\n",
            ),
            concat!(r#"{"timestamp":"2026-11-23T21:00:01.000Z","payload":{"type":"error","message":"Usage Limit reached"}}"#, "\n"),
            concat!(r#"{"timestamp":7,"payload":{"type":"task_complete","error":{"codex_error_info":{"usage_limit_exceeded":{}},"message":null}}}"#, "\n"),
        ];
        for c in cases {
            let Some(theirs) = jq(&["-Rnr", cx], c.as_bytes()) else { return };
            let ls: Vec<&[u8]> = c.lines().map(|l| l.as_bytes()).collect();
            let ours: Vec<String> = codex_limit(&ls).into_iter().collect();
            assert_eq!(ours, lines_of(&theirs), "{}", c);
        }
    }

    #[test]
    fn turns_as_jq() {
        let prog = r#".message.content | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | first // "") end | .[0:16]"#;
        let cases = [
            r#"{"type":"user","message":{"content":"[agent-msg from=x] hello"}}"#,
            r#"{"type":"user","message":{"content":[{"type":"image"},{"type":"text","text":"typed by me, a long line"}]}}"#,
            r#"{"type":"user","message":{"content":[]}}"#,
            r#"{"type":"user","message":{"content":5}}"#,
            r#"{"type":"user","message":{"content":["s"]}}"#,
            r#"{"type":"user","message":"x"}"#,
            r#"{"type":"user","message":{"content":"é…ü日本語テキストですよね長い"}}"#,
        ];
        for c in cases {
            let Some(theirs) = jq(&["-r", prog], c.as_bytes()) else { return };
            let ours: Vec<String> = turn_text(c.as_bytes()).into_iter().collect();
            assert_eq!(ours, lines_of(&theirs), "{}", c);
        }
    }
}
