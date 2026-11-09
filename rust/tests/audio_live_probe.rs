//! 真实上游音频取流探针。
//!
//! 默认不跑（`#[ignore]`），联调时显式触发：
//!
//! ```text
//! cargo test --manifest-path rust/Cargo.toml --test audio_live_probe -- --ignored --nocapture
//! ```
//!
//! 真机截图只能说明「取流失败」，答不出三件事：上游给的是什么形状的音频
//! 信封、那个音频地址本身能不能下载、失败卡在传输层的哪一步。这条探针把
//! 三件事一次打印出来，让修复不再靠猜。
//!
//! 打印里只保留地址的域名与路径，查询串（签名）会被去掉。

mod common;

use common::{build_server, pool_json, TempDir};
use fqapi_core::endpoints::Params;
use serde_json::Value;

const UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 打印一个 JSON 值的形状：键名、数组长度、字符串长度。`video_model` 会被
/// 解开内层的 JSON 再打印 —— 音频信封的结构全在里面。
fn outline(value: &Value) -> String {
    let mut out = String::new();
    write_outline(value, 0, &mut out);
    out
}

fn write_outline(value: &Value, depth: usize, out: &mut String) {
    let pad = "  ".repeat(depth);
    match value {
        Value::Object(map) => {
            for (key, item) in map {
                if key == "video_model" {
                    if let Value::String(raw) = item {
                        match serde_json::from_str::<Value>(raw) {
                            Ok(inner) => {
                                out.push_str(&format!("{pad}{key}: (decoded)\n"));
                                write_outline(&inner, depth + 1, out);
                            }
                            Err(_) => {
                                out.push_str(&format!("{pad}{key}: <string len={}>\n", raw.len()));
                            }
                        }
                        continue;
                    }
                }
                match item {
                    Value::String(s) if s.len() > 120 => {
                        out.push_str(&format!("{pad}{key}: <string len={}>\n", s.len()));
                    }
                    Value::String(s) => {
                        out.push_str(&format!("{pad}{key}: {s:?}\n"));
                    }
                    Value::Array(items) => {
                        out.push_str(&format!("{pad}{key}: <array len={}>\n", items.len()));
                        if let Some(first) = items.first() {
                            write_outline(first, depth + 1, out);
                        }
                    }
                    Value::Object(_) => {
                        out.push_str(&format!("{pad}{key}:\n"));
                        write_outline(item, depth + 1, out);
                    }
                    other => {
                        out.push_str(&format!("{pad}{key}: {other}\n"));
                    }
                }
            }
        }
        Value::Array(items) => {
            out.push_str(&format!("{pad}<array len={}>\n", items.len()));
            if let Some(first) = items.first() {
                write_outline(first, depth + 1, out);
            }
        }
        Value::String(s) => {
            out.push_str(&format!("{pad}<string len={}>\n", s.len()));
        }
        other => {
            out.push_str(&format!("{pad}{other}\n"));
        }
    }
}

/// 收集 payload 里所有指定键下的字符串值。
fn find_all_str(value: &Value, keys: &[&str], out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            for (key, item) in map {
                if keys.contains(&key.as_str()) {
                    if let Some(text) = item.as_str() {
                        if !text.is_empty() && !out.contains(&text.to_string()) {
                            out.push(text.to_string());
                        }
                    }
                }
                find_all_str(item, keys, out);
            }
        }
        Value::Array(items) => {
            for item in items {
                find_all_str(item, keys, out);
            }
        }
        _ => {}
    }
}

/// 去掉查询串，只留域名与路径：查询串里是签名，不该进日志。
fn safe_url(raw: &str) -> String {
    match raw.split_once('?') {
        Some((head, _)) => head.to_string(),
        None => raw.to_string(),
    }
}

/// 从 payload 里取出所有音频地址，以及它们各自的加密标记。
fn audio_streams(payload: &Value) -> Vec<(String, bool, bool)> {
    let mut raw_models: Vec<String> = Vec::new();
    find_all_str(payload, &["video_model"], &mut raw_models);
    let mut out: Vec<(String, bool, bool)> = Vec::new();
    for raw in raw_models {
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
            let has_key = item
                .get("encrypt_info")
                .and_then(|v| v.as_object())
                .and_then(|info| info.get("key_hex"))
                .and_then(|v| v.as_str())
                .is_some();
            for field in ["main_url", "backup_url"] {
                if let Some(url) = item.get(field).and_then(|v| v.as_str()) {
                    if !url.is_empty() {
                        out.push((url.to_string(), encrypted, has_key));
                    }
                }
            }
        }
    }
    out
}

/// 直接用 reqwest 打一次那个音频地址，把传输层的真实原因打印出来。
///
/// 只取开头 64 KB：连得上的地址会立刻回一段字节，连不上的会在握手阶段
/// 就失败 —— 这正是要区分的两件事，不必为此下完整个章节。
async fn try_download(url: &str, label: &str) {
    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
    {
        Ok(client) => client,
        Err(err) => {
            println!("[{label}] client build failed: {err}");
            return;
        }
    };
    match client
        .get(url)
        .header(reqwest::header::USER_AGENT, UA)
        .header(reqwest::header::RANGE, "bytes=0-65535")
        .send()
        .await
    {
        Ok(mut resp) => {
            println!(
                "[{label}] status={} content-length={:?}",
                resp.status(),
                resp.content_length()
            );
            match resp.chunk().await {
                Ok(Some(bytes)) => {
                    let head = &bytes[..bytes.len().min(48)];
                    println!(
                        "[{label}] first chunk={} bytes head={:?}",
                        bytes.len(),
                        String::from_utf8_lossy(head)
                    );
                }
                Ok(None) => println!("[{label}] empty body"),
                Err(err) => println!("[{label}] body error: {err}"),
            }
        }
        Err(err) => {
            println!("[{label}] error: {err}");
            let mut source = std::error::Error::source(&err);
            while let Some(cause) = source {
                println!("[{label}]   caused by: {cause}");
                source = cause.source();
            }
        }
    }
}

#[tokio::test]
#[ignore = "hits the live upstream"]
async fn live_audio_probe() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let dir = TempDir::new("audio-live");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    // ---- 1. 找一本有听书版本的书 ----
    let mut book_ids: Vec<String> = Vec::new();
    if let Some(search) = srv.handler("search") {
        let params = Params::from_pairs(vec![("query".to_string(), "入赘三年".to_string())]);
        match search(&srv.ctx, &params).await {
            Ok(value) => {
                println!("=== search outline ===\n{}", outline(&value));
                find_all_str(&value, &["book_id", "bookId"], &mut book_ids);
            }
            Err(err) => println!("search failed: {err:?}"),
        }
    }
    if book_ids.is_empty() {
        if let Some(home) = srv.handler("homepage_recommend") {
            let params = Params::from_pairs(vec![("tab_type".to_string(), "2".to_string())]);
            match home(&srv.ctx, &params).await {
                Ok(value) => {
                    println!("=== homepage outline ===\n{}", outline(&value));
                    find_all_str(&value, &["book_id", "bookId"], &mut book_ids);
                }
                Err(err) => println!("homepage failed: {err:?}"),
            }
        }
    }
    println!("=== candidate book ids: {book_ids:?}");
    if book_ids.is_empty() {
        panic!("no book id could be discovered; the upstream search is unreachable");
    }

    // ---- 2. 取第一章 ----
    let directory = srv.handler("directory").expect("route");
    let mut book_id = String::new();
    let mut chapter_id = String::new();
    for candidate in book_ids.iter().take(4) {
        let params = Params::from_pairs(vec![("book_id".to_string(), candidate.clone())]);
        match directory(&srv.ctx, &params).await {
            Ok(value) => {
                println!("=== directory {candidate} outline ===\n{}", outline(&value));
                let mut ids: Vec<String> = Vec::new();
                find_all_str(
                    &value,
                    &["item_id", "itemId", "chapter_id", "chapterId"],
                    &mut ids,
                );
                if let Some(first) = ids.first() {
                    book_id = candidate.clone();
                    chapter_id = first.clone();
                    break;
                }
            }
            Err(err) => println!("directory {candidate} failed: {err:?}"),
        }
    }
    println!("=== using book_id={book_id} chapter_id={chapter_id}");
    if chapter_id.is_empty() {
        panic!("no chapter id could be discovered");
    }

    // ---- 3. 逐个音色取流 ----
    let audio = srv.handler("audio_chapter_info").expect("route");
    for tone in ["0", "1", "2", "3", "99"] {
        let params = Params::from_pairs(vec![
            ("book_id".to_string(), book_id.clone()),
            ("chapter_id".to_string(), chapter_id.clone()),
            ("tone_id".to_string(), tone.to_string()),
        ]);
        let raw = match audio(&srv.ctx, &params).await {
            Ok(value) => {
                println!("=== tone {tone} raw outline ===\n{}", outline(&value));
                for (url, encrypted, has_key) in audio_streams(&value) {
                    println!(
                        "    stream encrypted={encrypted} key_hex={has_key} url={}",
                        safe_url(&url)
                    );
                }
                value
            }
            Err(err) => {
                println!("=== tone {tone} raw failed: {err:?}");
                continue;
            }
        };

        // 只有第一个音色真的走下载：服务端那条路会把整章下完，探针不必
        // 重复五遍。它顺带给出真机上会显示的那句原因。
        if tone != "0" {
            // 但每个音色的音频地址都要打一次：真人讲书与智能朗读的地址
            // 可能来自不同的 CDN，失败的原因也可能完全不同。
            for (url, _, _) in audio_streams(&raw) {
                try_download(&url, &format!("tone{tone}")).await;
            }
            continue;
        }

        let params = Params::from_pairs(vec![
            ("book_id".to_string(), book_id.clone()),
            ("chapter_id".to_string(), chapter_id.clone()),
            ("tone_id".to_string(), tone.to_string()),
            ("mode".to_string(), "plain".to_string()),
        ]);
        match audio(&srv.ctx, &params).await {
            Ok(value) => {
                println!("=== tone {tone} plain outline ===\n{}", outline(&value));
            }
            Err(err) => println!("=== tone {tone} plain failed: {err:?}"),
        }
    }
}
