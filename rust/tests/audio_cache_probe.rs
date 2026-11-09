//! 真实上游「服务端缓存 + Range 解密」端到端探针。
//!
//! `audio_live_probe` 回答了「上游给的音频是不是 CENC 加密、密钥在不在」，
//! 但没有回答真机最关键的问题：**iOS 走的那条路到底能不能成**。
//!
//! 真机只给得出「这个声音需要解码」「音频加载失败」，答不出失败发生在
//! 哪一步：取流、下载、缓存，还是按 Range 解密。iOS 的 `mode=plain` 让核心
//! 把整章缓存进 `src/` 再按 Range 解密成明文，这条路上任何一步断了，
//! Dart 都会退回带密钥的直连地址 —— iPhone 解不开，就变成 4901。
//!
//! 这条探针把那条路完整跑一遍：
//!
//! 1. 从真实上游取一章音频；
//! 2. 请求 `mode=plain`，打印核心的完整回答（成功给 `/src/*.mp4`，失败给
//!    4903 与脱敏后的真实原因）与耗时；
//! 3. 回答是 `/src/*.mp4` 时，从回环服务按 Range 取一段明文，与上游同一段
//!    原始字节逐字节对比 —— 证明「真的解密了」，而不是「把加密原样转发」；
//! 4. 检查 sample entry 是否从 `enca` 改写成了 `mp4a`。
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test audio_cache_probe -- --ignored --nocapture
//! ```

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use common::{build_server, pool_json, start_loopback, TempDir};
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

/// 已确认上游会回 `data[].video_model` 形状的有声书。用它当首选，省掉一次
/// 首页扫描；它失效了再退回扫描。
const KNOWN_BOOK: &str = "7361653460183288894";
const KNOWN_CHAPTER: &str = "7361654302949311038";

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

/// 找一本真正的有声书和它的第一章。
async fn resolve_audio_book(srv: &Arc<Server>) -> Option<(String, String)> {
    let detail = srv.handler("audio_book_detail")?;
    let directory = srv.handler("directory")?;
    let home = srv.handler("homepage_recommend")?;

    let mut ids: Vec<String> = Vec::new();
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
    ids.insert(0, KNOWN_BOOK.to_string());

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
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;
    let lb = start_loopback(srv.clone()).await;

    let Some((book_id, chapter_id)) = resolve_audio_book(&srv).await else {
        println!("=== no audio book could be resolved; nothing to probe");
        return;
    };
    println!("=== probing book_id={book_id} chapter_id={chapter_id}");

    let chapter_info = srv.handler("audio_chapter_info").expect("route");

    for tone in ["1", "2", "0"] {
        println!("\n===== tone {tone} =====");

        // 直连答案：用来取原始字节做对比。
        let direct = chapter_info(
            &srv.ctx,
            &Params::from_pairs(vec![
                ("book_id".to_string(), book_id.clone()),
                ("chapter_id".to_string(), chapter_id.clone()),
                ("tone_id".to_string(), tone.to_string()),
            ]),
        )
        .await;
        let direct = match direct {
            Ok(value) => value,
            Err(err) => {
                println!("[tone {tone}] direct failed: {err:?}");
                continue;
            }
        };
        let urls = audio_urls(&direct);
        println!("[tone {tone}] direct streams: {}", urls.len());
        for (url, encrypted) in urls.iter().take(4) {
            println!(
                "[tone {tone}]   encrypted={encrypted} url={}",
                sanitize(url)
            );
        }

        // 服务端缓存 + 解密。
        let started = Instant::now();
        let plain = chapter_info(
            &srv.ctx,
            &Params::from_pairs(vec![
                ("book_id".to_string(), book_id.clone()),
                ("chapter_id".to_string(), chapter_id.clone()),
                ("tone_id".to_string(), tone.to_string()),
                ("mode".to_string(), "plain".to_string()),
            ]),
        )
        .await;
        let elapsed = started.elapsed();
        let plain = match plain {
            Ok(value) => value,
            Err(err) => {
                println!("[tone {tone}] mode=plain failed after {elapsed:?}: {err:?}");
                continue;
            }
        };
        println!(
            "[tone {tone}] mode=plain took {elapsed:?}; answer: {}",
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
            println!("[tone {tone}] no cached stream; the answer above says why");
            continue;
        }

        let (status, decrypted) = match fetch_range(&lb.url(&served), 65535).await {
            Ok(pair) => pair,
            Err(err) => {
                println!("[tone {tone}] loopback fetch failed: {err}");
                continue;
            }
        };
        println!(
            "[tone {tone}] loopback status={status} bytes={}",
            decrypted.len()
        );

        let Some((raw_url, _)) = urls.iter().find(|(url, encrypted)| {
            *encrypted && url.starts_with("https://")
        }) else {
            println!("[tone {tone}] no encrypted upstream url to compare against");
            continue;
        };
        let (raw_status, raw) = match fetch_range(raw_url, 65535).await {
            Ok(pair) => pair,
            Err(err) => {
                println!("[tone {tone}] upstream fetch failed: {err}");
                continue;
            }
        };
        println!("[tone {tone}] upstream status={raw_status} bytes={}", raw.len());
        println!(
            "[tone {tone}] identical bytes: {} (false means the bytes were decrypted)",
            raw == decrypted
        );
        for marker in ["enca", "mp4a", "encv", "hvc1", "senc"] {
            println!(
                "[tone {tone}] marker {marker:?}: raw={:?} decrypted={:?}",
                find_bytes(&raw, marker.as_bytes()),
                find_bytes(&decrypted, marker.as_bytes())
            );
        }
    }
}
