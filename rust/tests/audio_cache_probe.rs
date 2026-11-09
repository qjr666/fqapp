//! 真实上游「服务端缓存 + Range 解密」端到端探针。
//!
//! `audio_live_probe` 回答了「上游给的音频是不是 CENC 加密、密钥在不在」，
//! 但没有回答真机最关键的问题：**iOS 走的那条路到底能不能成**。
//!
//! 真机只给得出「这个声音需要解码」「音频加载失败」「播放出错」，答不出
//! 失败发生在哪一步：取流、下载、缓存，还是按 Range 解密。iOS 的
//! `mode=plain` 让核心把整章缓存进 `src/` 再按 Range 解密成明文，这条路上
//! 任何一步断了，Dart 都会退回带密钥的直连地址 —— iPhone 解不开，就变成
//! 4901。
//!
//! 这条探针把那条路完整跑一遍：
//!
//! 1. 找到真机上正在听的那本书，分别取出它的「智能朗读」音色 id 与
//!    「真人讲书」主播的 abook_id；
//! 2. 对每一种听法请求 `mode=plain`，打印核心的完整回答（成功给
//!    `/src/*.mp4`，失败给 4903 与脱敏后的真实原因）与耗时；
//! 3. 回答是 `/src/*.mp4` 时，从回环服务按 Range 取一段明文，与上游同一段
//!    原始字节逐字节对比 —— 证明「真的解密了」，而不是「把加密原样转发」；
//! 4. 重复取同一个音色若干次，统计上游返回空 body 的比例 —— 上游对某个
//!    设备身份会偶发回一个零字节的 200，不重试就只是一句「播放出错」。
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test audio_cache_probe -- --ignored --nocapture
//! ```

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::{build_server, pool_json, start_loopback, Loopback, TempDir};
use fqapi_core::endpoints::{Params, Server};
use serde_json::Value;

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 章节号的各种可能叫法。
const ITEM_KEYS: &[&str] = &[
    "item_id",
    "itemId",
    "chapter_id",
    "chapterId",
    "item_ids",
    "itemIds",
];

/// 真机上正在测试的那本书。用标题去搜，避免把 id 写死在探针里。
const TARGET_TITLE: &str = "入赘三年";

/// 已确认上游会回 `data[].video_model` 形状的有声书，作为对照组。
const KNOWN_BOOK: &str = "7361653460183288894";

/// 递归收集所有指定键下的字符串值。
fn collect_strings(value: &Value, keys: &[&str], out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            for (key, item) in map {
                if keys.contains(&key.as_str()) {
                    if let Value::String(text) = item {
                        if !text.is_empty() {
                            out.push(text.clone());
                        }
                    }
                }
                collect_strings(item, keys, out);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_strings(item, keys, out);
            }
        }
        _ => {}
    }
}

/// 拆开 `data` 包装，取出真正放数据的对象。
fn data_of(value: &Value) -> &Value {
    match value.get("data") {
        Some(inner) if inner.is_object() => data_of(inner),
        _ => value,
    }
}

/// 从一个音色列表里取出音色 id。
fn tone_ids(value: &Value, key: &str) -> Vec<String> {
    let mut out = Vec::new();
    let Some(Value::Array(list)) = data_of(value).get(key) else {
        return out;
    };
    for entry in list {
        let Some(obj) = entry.as_object() else {
            continue;
        };
        for id_key in ["id", "tone_id"] {
            match obj.get(id_key) {
                Some(Value::String(text)) if !text.is_empty() => {
                    out.push(text.clone());
                    break;
                }
                Some(Value::Number(num)) => {
                    out.push(num.to_string());
                    break;
                }
                _ => {}
            }
        }
    }
    out
}

/// 智能朗读用的**原著**书号：TTS 走的是原著的章节 id。
fn related_novel_id(value: &Value) -> Option<String> {
    let data = data_of(value);
    for key in ["relate_novel_bookid_str", "relate_novel_bookid"] {
        match data.get(key) {
            Some(Value::String(text)) if !text.is_empty() && text != "0" => {
                return Some(text.clone());
            }
            Some(Value::Number(num)) => {
                let text = num.to_string();
                if text != "0" {
                    return Some(text);
                }
            }
            _ => {}
        }
    }
    None
}

/// 把一小段 JSON 打成一行，便于在探针日志里看清形状。
fn json_line(value: Option<&Value>) -> String {
    match value {
        Some(v) => serde_json::to_string(v).unwrap_or_default(),
        None => "none".to_string(),
    }
}

/// 从 `audio_tones` 里取出真人讲书主播的 abook_id。
fn narrator_ids(value: &Value) -> Vec<String> {
    let mut out = Vec::new();
    let Some(Value::Array(list)) = data_of(value).get("audio_tones") else {
        return out;
    };
    for entry in list {
        let Some(obj) = entry.as_object() else {
            continue;
        };
        let mut found: Option<String> = None;
        for id_key in ["abook_id_str", "book_id"] {
            if let Some(Value::String(text)) = obj.get(id_key) {
                if !text.is_empty() {
                    found = Some(text.clone());
                    break;
                }
            }
        }
        if found.is_none() {
            if let Some(Value::Number(num)) = obj.get("abook_id") {
                found = Some(num.to_string());
            }
        }
        if let Some(id) = found {
            out.push(id);
        }
    }
    out
}

/// 从回答里取出所有可播放的音频地址，并标记它是否带加密信息。
fn audio_urls(value: &Value) -> Vec<(String, bool)> {
    let mut models: Vec<String> = Vec::new();
    collect_strings(value, &["video_model"], &mut models);
    let mut out: Vec<(String, bool)> = Vec::new();
    for raw in models {
        let Ok(Value::Object(model)) = serde_json::from_str::<Value>(&raw) else {
            continue;
        };
        let Some(list) = model.get("video_list").and_then(|v| v.as_array()) else {
            continue;
        };
        for stream in list {
            let Some(item) = stream.as_object() else {
                continue;
            };
            let encrypted = item
                .get("encrypt_info")
                .and_then(|v| v.as_object())
                .and_then(|info| info.get("encrypt"))
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            for field in ["main_url", "backup_url"] {
                if let Some(Value::String(url)) = item.get(field) {
                    if !url.is_empty() {
                        out.push((url.clone(), encrypted));
                    }
                }
            }
        }
    }
    out
}

/// 打印上游信封的形状：数组型 `data[]` 还是 mget 型 `data{...}`。
fn envelope_shape(value: &Value) -> String {
    match value.get("data") {
        Some(Value::Array(rows)) => format!("data[] len={}", rows.len()),
        Some(Value::Object(obj)) => {
            let mut parts: Vec<String> = Vec::new();
            for (key, item) in obj {
                let kind = match item {
                    Value::Array(list) => format!("array({})", list.len()),
                    Value::Object(_) => "object".to_string(),
                    _ => "scalar".to_string(),
                };
                parts.push(format!("{key}:{kind}"));
            }
            format!("data{{{}}}", parts.join(","))
        }
        _ => "no data".to_string(),
    }
}

/// 把回答里的签名地址换成域名，避免探针日志留下可用的临时凭证。
fn sanitize(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(at) = rest.find("https://") {
        out.push_str(&rest[..at]);
        let tail = &rest[at..];
        let end = tail
            .find(|c: char| c.is_whitespace() || c == '"' || c == '\'')
            .unwrap_or(tail.len());
        let host = tail[..end]
            .trim_start_matches("https://")
            .split('/')
            .next()
            .unwrap_or("")
            .trim_end_matches(['"', '\'']);
        out.push_str(host);
        rest = &tail[end..];
    }
    out.push_str(rest);
    out
}

/// 在字节里找一个子串，返回第一次出现的位置。
fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// 按 Range 取一段字节。返回 (状态码, 字节)。
async fn fetch_range(url: &str, end: u64) -> Result<(u16, Vec<u8>), String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(180))
        .build()
        .map_err(|e| e.to_string())?;
    let mut resp = client
        .get(url)
        .header(reqwest::header::USER_AGENT, UA)
        .header(reqwest::header::RANGE, format!("bytes=0-{end}"))
        .send()
        .await
        .map_err(|e| {
            let mut source = std::error::Error::source(&e);
            let mut chain = e.to_string();
            while let Some(cause) = source {
                chain.push_str(&format!(" | {cause}"));
                source = cause.source();
            }
            chain
        })?;
    let status = resp.status().as_u16();
    let mut buf: Vec<u8> = Vec::new();
    while buf.len() <= end as usize {
        match resp.chunk().await {
            Ok(Some(bytes)) => {
                if bytes.is_empty() {
                    break;
                }
                buf.extend_from_slice(&bytes);
            }
            Ok(None) => break,
            Err(err) => return Err(err.to_string()),
        }
    }
    Ok((status, buf))
}

/// 一条待验证的取流路径。
struct Case {
    label: String,
    book_id: String,
    chapter_id: String,
    tone_id: String,
}

/// 对一条路径跑完整的「服务端缓存 + Range 解密」验证。
async fn probe_case(srv: &Arc<Server>, lb: &Loopback, case: &Case) {
    println!("\n----- {} -----", case.label);
    println!(
        "book_id={} chapter_id={} tone_id={}",
        case.book_id, case.chapter_id, case.tone_id
    );

    let chapter_info = srv.handler("audio_chapter_info").expect("route");

    // 直连答案：用来取原始字节做对比，也用来确认上游这次答了什么。
    let direct = match chapter_info(
        &srv.ctx,
        &Params::from_pairs(vec![
            ("book_id".to_string(), case.book_id.clone()),
            ("chapter_id".to_string(), case.chapter_id.clone()),
            ("tone_id".to_string(), case.tone_id.clone()),
        ]),
    )
    .await
    {
        Ok(value) => Some(value),
        Err(err) => {
            println!("[direct] failed: {err:?}");
            None
        }
    };
    let urls = match &direct {
        Some(value) => {
            println!("[direct] envelope: {}", envelope_shape(value));
            audio_urls(value)
        }
        None => Vec::new(),
    };
    println!("[direct] streams: {}", urls.len());
    for (url, encrypted) in urls.iter().take(4) {
        println!(
            "[direct]   encrypted={encrypted} url={}",
            sanitize(url)
        );
    }
    // 路径是对象的身份，域名只是它当前被下发到哪个 CDN。打印路径（去掉
    // 签名）才能把「哪个代能服务这条路径」和「哪个域名解析不了」分开。
    if let Some((url, _)) = urls.first() {
        let path = url.split("://").nth(1).unwrap_or("").split_once('/').map(|(_, rest)| rest);
        if let Some(path) = path {
            let path = path.split('?').next().unwrap_or(path);
            println!("[direct]   path={path}");
        }
    }

    // 上游是按客户端下发 CDN 域名的：换一台设备再问一次，看域名会不会变。
    // 会变的话，「第一台给的域名解析不了」就有第二条路可走。
    for round in 1..=2 {
        let repeat = chapter_info(
            &srv.ctx,
            &Params::from_pairs(vec![
                ("book_id".to_string(), case.book_id.clone()),
                ("chapter_id".to_string(), case.chapter_id.clone()),
                ("tone_id".to_string(), case.tone_id.clone()),
            ]),
        )
        .await;
        match repeat {
            Ok(value) => {
                let hosts: Vec<String> = audio_urls(&value)
                    .into_iter()
                    .map(|(url, _)| {
                        url.split("://")
                            .nth(1)
                            .unwrap_or("")
                            .split('/')
                            .next()
                            .unwrap_or("?")
                            .to_string()
                    })
                    .collect();
                println!("[hosts] round {round}: {}", hosts.join(", "));
            }
            Err(err) => println!("[hosts] round {round}: failed: {err:?}"),
        }
    }

    // 服务端缓存 + 解密。
    let started = Instant::now();
    let plain = chapter_info(
        &srv.ctx,
        &Params::from_pairs(vec![
            ("book_id".to_string(), case.book_id.clone()),
            ("chapter_id".to_string(), case.chapter_id.clone()),
            ("tone_id".to_string(), case.tone_id.clone()),
            ("mode".to_string(), "plain".to_string()),
        ]),
    )
    .await;
    let elapsed = started.elapsed();
    let plain = match plain {
        Ok(value) => value,
        Err(err) => {
            println!("[plain] failed after {elapsed:?}: {err:?}");
            return;
        }
    };
    println!(
        "[plain] took {elapsed:?}; answer: {}",
        sanitize(&plain.to_string())
    );

    let served = plain
        .get("data")
        .and_then(|d| d.as_array())
        .and_then(|rows| rows.first())
        .and_then(|row| row.get("main_url"))
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if !served.starts_with("/src/") {
        println!("[plain] no cached stream; the answer above says why");
        return;
    }

    let (status, decrypted) = match fetch_range(&lb.url(&served), 65535).await {
        Ok(pair) => pair,
        Err(err) => {
            println!("[plain] loopback fetch failed: {err}");
            return;
        }
    };
    println!(
        "[plain] loopback status={status} bytes={}",
        decrypted.len()
    );

    let Some((raw_url, _)) = urls
        .iter()
        .find(|(url, encrypted)| *encrypted && url.starts_with("https://"))
    else {
        println!("[plain] no encrypted upstream url to compare against");
        return;
    };
    let (raw_status, raw) = match fetch_range(raw_url, 65535).await {
        Ok(pair) => pair,
        Err(err) => {
            println!("[plain] upstream fetch failed: {err}");
            return;
        }
    };
    println!("[plain] upstream status={raw_status} bytes={}", raw.len());
    println!(
        "[plain] identical bytes: {} (false means the bytes were decrypted)",
        raw == decrypted
    );
    for marker in ["enca", "mp4a", "Opus", "encv", "hvc1", "senc"] {
        println!(
            "[plain] marker {marker:?}: raw={:?} decrypted={:?}",
            find_bytes(&raw, marker.as_bytes()),
            find_bytes(&decrypted, marker.as_bytes())
        );
    }

    // CDN 降级阶梯：上游按客户端下发域名，真机拿到的那个可能公网根本解析
    // 不了。这里把阶梯上的每个主机都试一遍，验证「换一个主机，同一条路径
    // 仍然取得到同一份字节」——这是真机能不能出声的前提。
    probe_cdn_ladder(raw_url).await;
}

/// 逐个试 CDN 阶梯上的主机，打印谁真的能服务这条路径。
///
/// 打印的只有主机名与状态码：地址里的路径与签名是凭据，不能进日志。
async fn probe_cdn_ladder(raw_url: &str) {
    let candidates = fqapi_core::endpoints::video::cdn_host_candidates(raw_url);
    println!("[cdn] {} candidates", candidates.len());
    for candidate in candidates {
        let host = candidate
            .split("://")
            .nth(1)
            .unwrap_or("")
            .split('/')
            .next()
            .unwrap_or("?")
            .to_string();
        match fetch_range(&candidate, 1023).await {
            Ok((status, bytes)) => {
                println!("[cdn] {host} -> status={status} bytes={}", bytes.len());
            }
            Err(err) => {
                println!("[cdn] {host} -> failed: {err}");
            }
        }
    }
    probe_cdn_ladder_three_part(raw_url).await;
}

/// 真机拿到的主机名是三段的：版本号 + 集群标记 + 业务族
/// （`v95-ynkmtc-novelapp.fqnovelvod.com`）。这里用同一条路径造一个这样
/// 的地址，再走一遍阶梯：只要阶梯里有一个主机能服务这条路径，真机就能
/// 出声 —— 这正是上一版栽跟头的地方（族被解析错了，一个能用的主机都没
/// 生成出来）。
async fn probe_cdn_ladder_three_part(raw_url: &str) {
    let Some((_, rest)) = raw_url.split_once("://") else {
        return;
    };
    let Some((host, path)) = rest.split_once('/') else {
        return;
    };
    let family = host
        .split('.')
        .next()
        .unwrap_or(host)
        .rsplit('-')
        .next()
        .unwrap_or("novelapp");
    let synthetic = format!("https://v95-ynkmtc-{family}.fqnovelvod.com/{path}");
    println!("\n[cdn3] ladder of a three-part host");
    for candidate in fqapi_core::endpoints::video::cdn_host_candidates(&synthetic) {
        let host = candidate
            .split("://")
            .nth(1)
            .unwrap_or("")
            .split('/')
            .next()
            .unwrap_or("?")
            .to_string();
        match fetch_range(&candidate, 1023).await {
            Ok((status, bytes)) => {
                println!("[cdn3] {host} -> status={status} bytes={}", bytes.len());
            }
            Err(err) => {
                println!("[cdn3] {host} -> failed: {err}");
            }
        }
    }
}

/// 同一个音色连续取若干次，统计上游回空 body 的比例。
async fn probe_flakiness(srv: &Arc<Server>, book_id: &str, chapter_id: &str, tone_id: &str) {
    println!("\n----- flakiness (tone {tone_id}) -----");
    let chapter_info = srv.handler("audio_chapter_info").expect("route");
    let mut empty = 0usize;
    let mut ok = 0usize;
    for round in 1..=4 {
        let started = Instant::now();
        let result = chapter_info(
            &srv.ctx,
            &Params::from_pairs(vec![
                ("book_id".to_string(), book_id.to_string()),
                ("chapter_id".to_string(), chapter_id.to_string()),
                ("tone_id".to_string(), tone_id.to_string()),
            ]),
        )
        .await;
        match result {
            Ok(_) => {
                ok += 1;
                println!("[round {round}] ok in {:?}", started.elapsed());
            }
            Err(err) => {
                let message = err.message().to_string();
                if message.starts_with("parse upstream json: EOF") {
                    empty += 1;
                }
                println!("[round {round}] failed in {:?}: {message}", started.elapsed());
            }
        }
    }
    println!("[flakiness] ok={ok} empty_body={empty}");
}

/// 一本候选书，以及它身上两种听法的入口。
struct Candidate {
    /// 书号本身。
    id: String,
    /// 智能朗读的音色 id（`tts_tones`）。
    tts_tones: Vec<String>,
    /// App 真正会拿去请求的音色：可选集非空时等于可选集。
    probe_tones: Vec<String>,
    /// 真人讲书主播的 abook_id（`audio_tones`）。
    narrators: Vec<String>,
    /// 智能朗读实际要用的原著书号（TTS 走原著的章节 id）。
    related_novel: Option<String>,
}

/// 找出真机上那本书的「智能朗读」音色与「真人讲书」主播。
///
/// 返回**全部**候选：搜索会命中好几本同名的书，其中只有一部分带
/// `tts_tones`、只有一部分带 `audio_tones`。早先的版本命中第一本就返回，
/// 于是「智能朗读」那一支经常一次都没跑过——书找到了，音色却是空的。
async fn resolve_candidates(srv: &Arc<Server>) -> Vec<Candidate> {
    let Some(search) = srv.handler("search") else {
        return Vec::new();
    };
    let Some(tones) = srv.handler("tones") else {
        return Vec::new();
    };
    let Some(directory) = srv.handler("directory") else {
        return Vec::new();
    };

    let params = Params::from_pairs(vec![("query".to_string(), TARGET_TITLE.to_string())]);
    let mut ids: Vec<String> = Vec::new();
    match search(&srv.ctx, &params).await {
        Ok(value) => {
            collect_strings(&value, &["book_id", "bookId"], &mut ids);
            println!("=== search '{TARGET_TITLE}' found {} ids", ids.len());
        }
        Err(err) => println!("search failed: {err:?}"),
    }
    if ids.is_empty() {
        return Vec::new();
    }

    let mut out = Vec::new();
    for id in ids.iter().take(8) {
        let params = Params::from_pairs(vec![("book_id".to_string(), id.clone())]);
        let detail = match tones(&srv.ctx, &params).await {
            Ok(value) => value,
            Err(err) => {
                println!("tones {id} failed: {err:?}");
                continue;
            }
        };
        let data = data_of(&detail);
        let tts = tone_ids(&detail, "tts_tones");
        let offline = tone_ids(&detail, "offline_tts_tones");
        let narrators = narrator_ids(&detail);
        let novel = related_novel_id(&detail);
        println!(
            "=== book {id}: tts_tones={:?} narrators={:?} related_novel={:?}",
            tts, narrators, novel
        );
        // App 的 `_selectableTone` 会把离线音色和主播 id 排除在可选列表外。
        // 如果可选集是空的，智能朗读面板就没有任何可选的声音——真机看到
        // 的「无法使用」其实是「根本没得选」。
        let selectable: Vec<&String> = tts
            .iter()
            .filter(|tone| !offline.contains(*tone) && !narrators.contains(*tone))
            .collect();
        println!("[tones] offline_tts_tones={:?} selectable={:?}", offline, selectable);
        println!(
            "[tones] tts_tones[0] = {}",
            json_line(data.get("tts_tones").and_then(|v| v.as_array()).and_then(|l| l.first()))
        );
        println!(
            "[tones] audio_tones[0] = {}",
            json_line(data.get("audio_tones").and_then(|v| v.as_array()).and_then(|l| l.first()))
        );
        if tts.is_empty() && narrators.is_empty() {
            continue;
        }
        // 章节是否能取到决定这本书能不能被探针真的跑起来，顺手记下来。
        let mut chapters: Vec<String> = Vec::new();
        if let Ok(value) = directory(&srv.ctx, &params).await {
            collect_strings(&value, ITEM_KEYS, &mut chapters);
        }
        if chapters.is_empty() {
            println!("book {id} has no chapter id");
        }
        out.push(Candidate {
            id: id.clone(),
            probe_tones: if selectable.is_empty() {
                tts.clone()
            } else {
                selectable.iter().map(|tone| (*tone).clone()).collect()
            },
            tts_tones: tts,
            narrators,
            related_novel: novel,
        });
    }
    out
}

/// 递归找第一个同名键。
fn find_first(value: &Value, key: &str, depth: usize) -> Option<Value> {
    if depth > 6 {
        return None;
    }
    match value {
        Value::Object(map) => {
            if let Some(found) = map.get(key) {
                return Some(found.clone());
            }
            for child in map.values() {
                if let Some(found) = find_first(child, key, depth + 1) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(items) => {
            for item in items {
                if let Some(found) = find_first(item, key, depth + 1) {
                    return Some(found);
                }
            }
            None
        }
        _ => None,
    }
}

/// 一条章节的 id。
fn chapter_id(value: &Value) -> Option<String> {
    let map = value.as_object()?;
    for key in ["item_id", "itemId"] {
        match map.get(key) {
            Some(Value::String(text)) if !text.is_empty() => return Some(text.clone()),
            Some(Value::Number(num)) => return Some(num.to_string()),
            _ => {}
        }
    }
    None
}

/// 按 **App 的读法** 取目录里的章节 id。
///
/// App 走 `/api/v1/books/{id}/directory`，Dart 侧 `parseDirectory` 先找
/// `chapterListWithVolume`（每卷一个 `chapterList`），再退回
/// `episodes` / `item_data_list` / `lists` / `item_list`。探针必须用同一套
/// 读法：否则验的是 App 根本不会请求的章节 id，绿灯也是假的。
fn app_directory_chapters(value: &Value) -> Vec<String> {
    if let Some(Value::Array(volumes)) = find_first(value, "chapterListWithVolume", 0) {
        let mut out = Vec::new();
        for volume in volumes {
            let Some(volume) = volume.as_object() else {
                continue;
            };
            let list = volume
                .get("chapterList")
                .or_else(|| volume.get("chapter_list"));
            let Some(Value::Array(chapters)) = list else {
                continue;
            };
            for chapter in chapters {
                if let Some(id) = chapter_id(chapter) {
                    out.push(id);
                }
            }
        }
        if !out.is_empty() {
            return out;
        }
    }
    for key in ["episodes", "item_data_list", "lists", "item_list"] {
        if let Some(Value::Array(items)) = find_first(value, key, 0) {
            let out: Vec<String> = items.iter().filter_map(chapter_id).collect();
            if !out.is_empty() {
                return out;
            }
        }
    }
    Vec::new()
}

/// App 打开一本书时拿到的第一个章节 id。
async fn app_first_chapter(srv: &Arc<Server>, book_id: &str) -> Option<String> {
    let directory = srv.handler("directory")?;
    let params = Params::from_pairs(vec![("book_id".to_string(), book_id.to_string())]);
    let value = directory(&srv.ctx, &params).await.ok()?;
    let chapters = app_directory_chapters(&value);
    println!(
        "[directory] {book_id}: {} chapters (app parser), first={:?}",
        chapters.len(),
        chapters.first()
    );
    chapters.first().cloned()
}

/// 取一本书的第一章 id。
///
/// 三条路都要试：真人讲书那本走音频详情，智能朗读关联的原著走目录，而
/// 目录又有「阅读目录」和「小说目录」两种上游。
async fn first_chapter(srv: &Arc<Server>, book_id: &str) -> Option<String> {
    let detail = srv.handler("audio_book_detail")?;
    let directory = srv.handler("directory")?;

    let mut items: Vec<String> = Vec::new();
    let params = Params::from_pairs(vec![("book_id".to_string(), book_id.to_string())]);
    if let Ok(value) = detail(&srv.ctx, &params).await {
        collect_strings(&value, ITEM_KEYS, &mut items);
    }
    if items.is_empty() {
        if let Ok(value) = directory(&srv.ctx, &params).await {
            collect_strings(&value, ITEM_KEYS, &mut items);
        }
    }
    if items.is_empty() {
        let novel = Params::from_pairs(vec![
            ("book_id".to_string(), book_id.to_string()),
            ("api_type".to_string(), "novel".to_string()),
        ]);
        if let Ok(value) = directory(&srv.ctx, &novel).await {
            collect_strings(&value, ITEM_KEYS, &mut items);
        }
    }
    items.first().cloned()
}

/// 找一本真正的有声书和它的第一章，当对照组。
async fn resolve_audio_book(srv: &Arc<Server>) -> Option<(String, String)> {
    let detail = srv.handler("audio_book_detail")?;
    let directory = srv.handler("directory")?;
    let home = srv.handler("homepage_recommend")?;

    let mut ids: Vec<String> = vec![KNOWN_BOOK.to_string()];
    for tab_type in ["0", "2", "3"] {
        let params = Params::from_pairs(vec![("tab_type".to_string(), tab_type.to_string())]);
        if let Ok(value) = home(&srv.ctx, &params).await {
            let mut found: Vec<String> = Vec::new();
            collect_strings(&value, &["audio_book_id", "audio_id", "book_id"], &mut found);
            for id in found {
                if !ids.contains(&id) {
                    ids.push(id);
                }
            }
        }
    }

    for id in ids.iter().take(12) {
        let params = Params::from_pairs(vec![("book_id".to_string(), id.clone())]);
        let mut items: Vec<String> = Vec::new();
        if let Ok(value) = detail(&srv.ctx, &params).await {
            collect_strings(&value, ITEM_KEYS, &mut items);
        }
        if items.is_empty() {
            if let Ok(value) = directory(&srv.ctx, &params).await {
                collect_strings(&value, ITEM_KEYS, &mut items);
            }
        }
        if let Some(first) = items.first() {
            return Some((id.clone(), first.clone()));
        }
    }
    None
}

#[tokio::test]
#[ignore = "hits the live upstream"]
async fn live_audio_cache_probe() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let dir = TempDir::new("audio-cache");
    // An empty pool makes the core register real devices with the upstream,
    // the same way the app does on a fresh install. A hand-written pool of
    // fake identities would not rotate the way the app's does, and the
    // rotation is exactly what the empty-body retry depends on.
    let srv = build_server(&dir, None, &[], &[], &pool_json(0)).await;
    let lb = start_loopback(srv.clone()).await;
    println!("=== device pool size: {}", srv.ctx.pool.count().await);

    // ---- 对照组：一本有声书 ----
    if let Some((book_id, chapter_id)) = resolve_audio_book(&srv).await {
        for tone in ["2", "0"] {
            probe_case(
                &srv,
                &lb,
                &Case {
                    label: format!("有声书 {book_id} tone {tone}"),
                    book_id: book_id.clone(),
                    chapter_id: chapter_id.clone(),
                    tone_id: tone.to_string(),
                },
            )
            .await;
        }
        probe_flakiness(&srv, &book_id, &chapter_id, "2").await;
    }

    // ---- 目标书：真机上正在听的那本 ----
    let candidates = resolve_candidates(&srv).await;
    println!("=== candidates: {}", candidates.len());

    // ---- 智能朗读：TTS 走的是**原著**的章节 id，音色取 tts_tones ----
    // App 选中智能朗读后会切到关联原著，用原著的章节 id 请求，tone_id 是
    // tts_tones 里的 id（绝不会是 0——0 属于真人讲书那一支）。
    for candidate in candidates.iter().filter(|c| !c.probe_tones.is_empty()) {
        let tts_book = candidate
            .related_novel
            .clone()
            .unwrap_or_else(|| candidate.id.clone());
        // 先用 App 的取法（阅读目录），拿不到再退回其它上游——两者给出的
        // 章节 id 不一样时，App 只会用前者。
        let tts_chapter = match app_first_chapter(&srv, &tts_book).await {
            Some(chapter) => Some(chapter),
            None => first_chapter(&srv, &tts_book).await,
        };
        println!("=== 智能朗读 book={tts_book} chapter={tts_chapter:?}");
        let Some(chapter_id) = tts_chapter else {
            continue;
        };
        for tone in candidate.probe_tones.iter().take(3) {
            probe_case(
                &srv,
                &lb,
                &Case {
                    label: format!("智能朗读 {tts_book} tone {tone}"),
                    book_id: tts_book.clone(),
                    chapter_id: chapter_id.clone(),
                    tone_id: tone.clone(),
                },
            )
            .await;
        }
    }

    // ---- 真人讲书：主播那一本的章节 id，音色是 0（App 就是这么问的）----
    for candidate in candidates.iter() {
        for narrator in candidate.narrators.iter().take(2) {
            let abook_chapter = match app_first_chapter(&srv, narrator).await {
                Some(chapter) => Some(chapter),
                None => first_chapter(&srv, narrator).await,
            };
            println!("=== 真人讲书 book={narrator} chapter={abook_chapter:?}");
            let Some(chapter_id) = abook_chapter else {
                continue;
            };
            for tone in ["0"] {
                probe_case(
                    &srv,
                    &lb,
                    &Case {
                        label: format!("真人讲书 {narrator} tone {tone}"),
                        book_id: narrator.clone(),
                        chapter_id: chapter_id.clone(),
                        tone_id: tone.to_string(),
                    },
                )
                .await;
            }
        }
    }
}
