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
    let mut pairs: Vec<(String, String)> = Vec::new();
    collect_pairs(value, &mut pairs, |key, _| keys.contains(&key));
    for (_, value) in pairs {
        out.push(value);
    }
}

/// 收集 payload 里所有指定键下的字符串值，键名保持原样，方便区分
/// `audio_book_id`（有声书）与 `book_id`（小说）——两者混在一起会让上游
/// 返回空 body，探针却只能看到一句「解析失败」。
fn find_all_str_tagged(value: &Value, keys: &[&str], out: &mut Vec<(String, String)>) {
    collect_pairs(value, out, |key, _| keys.contains(&key));
}

fn collect_pairs(
    value: &Value,
    out: &mut Vec<(String, String)>,
    keep: impl Fn(&str, &str) -> bool,
) {
    match value {
        Value::Object(map) => {
            for (key, item) in map {
                if keep(key.as_str(), "") {
                    match item {
                        Value::String(text) => {
                            if !text.is_empty() {
                                push_pair(out, key, text);
                            }
                        }
                        // `item_ids` is usually a list, not a single string.
                        Value::Array(items) => {
                            for element in items {
                                if let Value::String(text) = element {
                                    if !text.is_empty() {
                                        push_pair(out, key, text);
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
                collect_pairs(item, out, &keep);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_pairs(item, out, &keep);
            }
        }
        _ => {}
    }
}

fn push_pair(out: &mut Vec<(String, String)>, key: &str, text: &str) {
    let pair = (key.to_string(), text.to_string());
    if !out.contains(&pair) {
        out.push(pair);
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
///
/// 拿到字节之后还要回答第三个问题：**这个文件到底加没加密**。CENC 的
/// 容器里会出现 `encv`（视频轨）、`enca`（音频轨）、`sinf`/`schm`/`tenc`
/// 这些标记；一个都没有就说明容器是明文的，播放器直接播即可，iPhone 不
/// 需要端上解密。这决定了修复该往哪走。
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
            let mut buf: Vec<u8> = Vec::new();
            while buf.len() < 65536 {
                match resp.chunk().await {
                    Ok(Some(bytes)) => {
                        buf.extend_from_slice(&bytes);
                        if bytes.is_empty() {
                            break;
                        }
                    }
                    Ok(None) => break,
                    Err(err) => {
                        println!("[{label}] body error: {err}");
                        break;
                    }
                }
            }
            if buf.is_empty() {
                println!("[{label}] empty body");
                return;
            }
            let head = &buf[..buf.len().min(32)];
            println!(
                "[{label}] got {} bytes, head={:?}",
                buf.len(),
                String::from_utf8_lossy(head)
            );
            // 明文 MP4 的第一个 box 一定是 ftyp；拿它当基准。
            if buf.len() >= 8 && &buf[4..8] == b"ftyp".as_slice() {
                println!("[{label}] container: MP4 (ftyp present)");
            } else {
                println!("[{label}] container: no ftyp box in the first bytes");
            }
            for marker in ["encv", "enca", "sinf", "schm", "tenc", "pssh", "senc"] {
                if let Some(at) = find_bytes(&buf, marker.as_bytes()) {
                    println!("[{label}] CENC marker {marker:?} found at byte {at}");
                }
            }
            if !has_cenc_marker(&buf) {
                println!("[{label}] CENC markers: NONE — the file looks like plain media");
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

/// 在字节里找一个子串，返回第一次出现的位置。
fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn has_cenc_marker(buf: &[u8]) -> bool {
    ["encv", "enca", "sinf", "schm", "tenc", "pssh", "senc"]
        .iter()
        .any(|marker| find_bytes(buf, marker.as_bytes()).is_some())
}

/// 章节号的各种可能叫法。
const ITEM_KEYS: &[&str] = &[
    "item_id",
    "itemId",
    "chapter_id",
    "chapterId",
    "item_ids",
    "itemIds",
];

#[tokio::test]
#[ignore = "hits the live upstream"]
async fn live_audio_probe() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let dir = TempDir::new("audio-live");
    let srv = build_server(&dir, None, &[], &[], &pool_json(1)).await;

    // ---- 1. 找一本真正的有声书 ----
    //
    // 有声书和小说共用一个 book_id 空间，但上游的 audio/playinfo 只认
    // 有声书自己的 id：拿小说 id 去问，上游会回一个空 body，于是探针只
    // 看得到「解析上游 JSON 失败」，看不到真正该看的东西。
    let home = srv.handler("homepage_recommend").expect("route");
    let mut tagged: Vec<(String, String)> = Vec::new();
    for tab_type in ["0", "2", "3"] {
        let params = Params::from_pairs(vec![("tab_type".to_string(), tab_type.to_string())]);
        match home(&srv.ctx, &params).await {
            Ok(value) => {
                println!("=== homepage tab {tab_type} outline ===\n{}", outline(&value));
                find_all_str_tagged(
                    &value,
                    &[
                        "audio_book_id",
                        "audio_id",
                        "book_id",
                        "bookId",
                        "item_id",
                    ],
                    &mut tagged,
                );
            }
            Err(err) => println!("homepage tab {tab_type} failed: {err:?}"),
        }
    }
    println!("=== tagged ids (first 40) ===");
    for (key, value) in tagged.iter().take(40) {
        println!("    {key} = {value}");
    }

    // 有声书 id 优先；实在没有才退回普通 book_id（可能是小说）。
    let mut candidates: Vec<String> = Vec::new();
    for (key, value) in &tagged {
        if key == "audio_book_id" || key == "audio_id" {
            if !candidates.contains(value) {
                candidates.push(value.clone());
            }
        }
    }
    let audio_candidates = candidates.len();
    for (key, value) in &tagged {
        if key == "book_id" || key == "bookId" {
            if !candidates.contains(value) {
                candidates.push(value.clone());
            }
        }
    }
    println!("=== audio candidates: {audio_candidates}, total candidates: {}", candidates.len());
    if candidates.is_empty() {
        panic!("no book id could be discovered; the upstream search is unreachable");
    }

    // ---- 2. 拿到 (有声书 id, 章节 id) ----
    let detail = srv.handler("audio_book_detail").expect("route");
    let directory = srv.handler("directory").expect("route");
    let mut pair: Option<(String, String)> = None;
    for candidate in candidates.iter().take(8) {
        let params = Params::from_pairs(vec![("book_id".to_string(), candidate.clone())]);
        let mut items: Vec<String> = Vec::new();
        match detail(&srv.ctx, &params).await {
            Ok(value) => {
                println!("=== audio detail {candidate} outline ===\n{}", outline(&value));
                find_all_str(&value, ITEM_KEYS, &mut items);
            }
            Err(err) => println!("audio detail {candidate} failed: {err:?}"),
        }
        if items.is_empty() {
            let params = Params::from_pairs(vec![("book_id".to_string(), candidate.clone())]);
            match directory(&srv.ctx, &params).await {
                Ok(value) => {
                    println!("=== audio directory {candidate} outline ===\n{}", outline(&value));
                    find_all_str(&value, ITEM_KEYS, &mut items);
                }
                Err(err) => println!("directory {candidate} failed: {err:?}"),
            }
        }
        if let Some(first) = items.first() {
            pair = Some((candidate.clone(), first.clone()));
            break;
        }
    }

    let Some((book_id, chapter_id)) = pair else {
        println!("=== no audio book could be resolved; nothing to probe");
        return;
    };
    println!("=== using book_id={book_id} chapter_id={chapter_id}");

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

        // 每个音色的音频地址都要打一次：真人讲书与智能朗读的地址可能来自
        // 不同的 CDN，失败的原因也可能完全不同。
        for (url, _, _) in audio_streams(&raw) {
            try_download(&url, &format!("tone{tone}")).await;
        }

        // 只有第一个音色走一次 plain（服务端缓存）那条路：它会把整章下完，
        // 探针不必重复五遍。它顺带给出真机上会显示的那句原因。
        if tone != "0" {
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
