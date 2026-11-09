//! Audio endpoints: book detail, chapter playinfo, audio play, and the
//! speech-text timeline.

use futures::future::BoxFuture;
use serde_json::{json, Map, Value};
use std::sync::OnceLock;
use std::time::Duration;

use crate::endpoints::base::{
    dragon_read_headers, dragon_read_json_headers, Upstream, UpstreamMode, UpstreamRequestSpec,
    HOST_FQNOVEL,
};
use crate::endpoints::util::{default_val, int_default, raw_json};
use crate::endpoints::{Ctx, Params, Server};
use crate::error::{ApiError, ApiResult};

/// Go's url.Values.Set.
pub(crate) fn set_param(params: &mut Vec<(String, String)>, key: &str, value: impl Into<String>) {
    let value = value.into();
    params.retain(|(k, _)| k != key);
    params.push((key.to_string(), value));
}

/// reading724Params from content_util.go (shared in `endpoints::base`).
pub(crate) fn reading_724_params() -> Vec<(String, String)> {
    crate::endpoints::base::reading724_params()
}

/// Audio book detail: GET /api/v1/audio/books/{id}.
const AUDIO_BOOK_DETAIL_PATH: &str = "/reading/bookapi/audio/detail/";

fn handle_book_detail<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        if book_id.is_empty() {
            return Err(ApiError::BadRequest("缺少book_id参数".to_string()));
        }

        let mut p = reading_724_params();
        set_param(&mut p, "version", "v3");
        set_param(&mut p, "book_id", book_id);

        Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: AUDIO_BOOK_DETAIL_PATH.to_string(),
                params: p,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await
    })
}

/// Audio chapter playinfo: GET /api/v1/audio/books/{id}/chapters/{cid}.
const AUDIO_CHAPTER_INFO_PATH: &str = "/reading/reader/audio/playinfo/";

fn handle_chapter_info<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let book_id = params.get_str("book_id");
        let chapter_id = params.get_str("chapter_id");
        if book_id.is_empty() || chapter_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少参数: book_id / chapter_id 均为必填".to_string(),
            ));
        }
        let tone_id = default_val(&params.get_str("tone_id"), "0");
        // iOS has no on-device CENC decryption. Callers that need a plain
        // stream ask for `mode=plain`; Android / Windows omit it and keep the
        // direct upstream URL + key_hex contract unchanged.
        let plain_mode = params.get_str("mode") == "plain";

        let mut p = reading_724_params();
        set_param(&mut p, "book_id", book_id);
        set_param(&mut p, "item_ids", chapter_id.clone());
        set_param(&mut p, "tone_id", tone_id.clone());
        set_param(&mut p, "req_type", "0");
        set_param(&mut p, "is_local_book", "false");

        let mut payload = Upstream::new(ctx.up.clone())
            .json(&UpstreamRequestSpec {
                mode: UpstreamMode::DeviceSigned,
                host: HOST_FQNOVEL.to_string(),
                path: AUDIO_CHAPTER_INFO_PATH.to_string(),
                params: p,
                headers: dragon_read_headers(),
                ..Default::default()
            })
            .await?;
        patch_playinfo_keys(&mut payload);
        if plain_mode {
            // 章节答案有两种信封：`data[].video_model` 与
            // `data.video_model_datas[].video_model`。key 派生之前只覆盖了
            // 前者，智能朗读因此拿不到 key_hex —— 核心与 Dart 两侧都会把它
            // 当成「没有可播的流」。两种信封都要补 key。
            patch_encrypted_audio_keys(&mut payload);
            let scan = encrypted_audio_candidates(&payload);
            let saw_encrypted = scan.saw_encrypted;
            let candidates = scan.candidates;
            if candidates.is_empty() && saw_encrypted {
                // The answer does carry an encrypted stream, we only failed to
                // recognise its shape. Handing the encrypted URL back would
                // leave iOS with a source it cannot play and a generic
                // failure message, so report the mismatch itself.
                log::warn!(
                    "audio plain: chapter {} tone {} has an encrypted stream in an unrecognised shape",
                    chapter_id,
                    tone_id
                );
                return Ok(json!({
                    "code": 0,
                    "data": [{
                        "item_id": chapter_id.clone(),
                        "code": 4903,
                        "message": "IOS_AUDIO_CACHE_FAILED: 上游返回了加密音频，但当前解析规则未能识别其结构",
                    }],
                }));
            }
            if candidates.is_empty() {
                // A genuinely clear stream needs no cache at all. Keeping the
                // upstream answer lets iOS open the signed URL directly.
                log::info!(
                    "audio plain: chapter {} tone {} has no encrypted stream; keeping the upstream answer",
                    chapter_id,
                    tone_id
                );
            } else {
                let base_id = audio_cache_id(&chapter_id, &tone_id);
                let mut last_err = String::from("no candidate attempted");
                let mut attempts: Vec<String> = Vec::new();

                // 第一轮：带密钥的候选。第一个候选沿用旧 id —— 设备上还可能
                // 留着上一版缓存的同名文件，命中它就不用重新下载整章。
                let keyed: Vec<&AudioCandidate> =
                    candidates.iter().filter(|c| !c.key.is_empty()).collect();
                for (index, candidate) in keyed.iter().enumerate() {
                    let cache_id = if index == 0 {
                        base_id.clone()
                    } else {
                        format!("{base_id}_{index}")
                    };
                    match crate::endpoints::video::download_and_save_with_timeout(
                        ctx,
                        &cache_id,
                        &candidate.url,
                        &candidate.key,
                        AUDIO_DOWNLOAD_TIMEOUT,
                    )
                    .await
                    {
                        Ok(served) => {
                            // `parsePlayinfoSource` walks the last envelope's
                            // `data` list. A bare `main_url` without
                            // `encrypt_info` hits its plain-stream branch, and
                            // `_mediaUrl` expands `/src/...` into the loopback
                            // URL that `serve_src_file` decrypts per Range.
                            return Ok(cached_audio_payload(&chapter_id, served, &attempts));
                        }
                        Err(err) => {
                            log::warn!(
                                "audio plain: chapter {} tone {} candidate {}/{} failed: {}",
                                chapter_id,
                                tone_id,
                                index + 1,
                                keyed.len(),
                                err
                            );
                            attempts.push(format!("带密钥候选 {}: {}", index + 1, err));
                            last_err = err;
                        }
                    }
                }

                // 第二轮：明文兜底。有些音色标称 encrypt=true，实际内容并没有
                // 加密；用空 key 下载一次，缓存里不写 key sidecar，播放器就能
                // 直接播放原始字节。只试第一个地址，避免把时间耗在同一个
                // 文件的副本上。
                if let Some(candidate) = candidates.first() {
                    let plain_id = format!("{base_id}_plain");
                    match crate::endpoints::video::download_and_save_with_timeout(
                        ctx,
                        &plain_id,
                        &candidate.url,
                        &[],
                        AUDIO_DOWNLOAD_TIMEOUT,
                    )
                    .await
                    {
                        Ok(served) => {
                            return Ok(cached_audio_payload(&chapter_id, served, &attempts));
                        }
                        Err(err) => {
                            log::warn!(
                                "audio plain: chapter {} tone {} plain fallback failed: {}",
                                chapter_id,
                                tone_id,
                                err
                            );
                            attempts.push(format!("明文兜底: {}", err));
                            last_err = err;
                        }
                    }
                }

                // 服务端确实没能拿到可解密的音频。给出带原因的业务码：iOS 端
                // 没有端上解密能力，把加密直连地址塞回去只会得到一句没有
                // 信息量的「播放出错」。
                log::warn!(
                    "audio plain: chapter {} tone {} exhausted {} candidates (last: {})",
                    chapter_id,
                    tone_id,
                    candidates.len(),
                    last_err
                );
                return Ok(json!({
                    "code": 0,
                    "data": [{
                        "item_id": chapter_id.clone(),
                        "code": 4903,
                        "message": format!(
                            "IOS_AUDIO_CACHE_FAILED: {}",
                            sanitize_cache_error(&last_err)
                        ),
                    }],
                }));
            }
        }
        Ok(payload)
    })
}

/// Collects every encrypted stream of a patched playinfo answer, paired with
/// a usable 16-byte key, in the order the player should try them.
///
/// The upstream switches envelope shape by book genre / tone: the chapter
/// endpoint normally answers `data[].video_model`, while some 智能朗读 voices
/// arrive in the mget-style `data.video_model_datas[].video_model`. Accepting
/// both, tolerating an absent `media_type`, deriving the key from `spade_a`
/// when `key_hex` is missing, and retrying `backup_url` is what keeps an
/// unfamiliar voice from silently falling back to the encrypted direct URL
/// that iOS cannot play.
/// 整章有声书的缓存下载预算。短剧一集只有几 MB，120 秒绰绰有余；一章
/// 真人讲书动辄十几分钟音频、几十 MB，手机网络下 120 秒经常下不完，缓存
/// 于是被判失败。回环服务对音频章节路由也放宽了同样的预算。
const AUDIO_DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(300);

/// One playable stream discovered in a patched playinfo answer.
struct AudioCandidate {
    url: String,
    /// The 16-byte CENC content key. Empty when the envelope carried none,
    /// which means the stream can only be cached as plain bytes.
    key: Vec<u8>,
}

/// What a scan of a playinfo answer found.
struct AudioScan {
    /// The playable streams, in the order the player should try them.
    candidates: Vec<AudioCandidate>,
    /// Whether the answer carried an encrypted stream at all. A scan that saw
    /// one but produced no candidate means the envelope shape was not
    /// understood — that must not be mistaken for "this stream is clear", or
    /// the caller hands iOS an encrypted URL it cannot play and reports a
    /// generic failure instead of the real mismatch.
    saw_encrypted: bool,
}

/// The answer the Dart side expects for a server-decrypted stream: a bare
/// `main_url` that the backend expands into the loopback URL.
fn cached_audio_payload(chapter_id: &str, served: String, attempts: &[String]) -> Value {
    json!({
        "code": 0,
        "data": [{
            "item_id": chapter_id,
            "main_url": served,
            "diag": { "attempts": attempts },
        }],
    })
}

/// Strips signed URLs out of an error before it can reach the screen: the
/// download errors carry the full request URL, and that URL is a credential.
/// The host is kept — it is the part that says *which* CDN answered, and
/// without it two different failures look identical — while the path and the
/// query, which carry the signature, are dropped.
fn sanitize_cache_error(err: &str) -> String {
    static URL_RE: OnceLock<regex::Regex> = OnceLock::new();
    let re = URL_RE.get_or_init(|| {
        regex::Regex::new(r"https?://([^\s/?#]+)[^)\s]*").expect("url regex")
    });
    let cleaned = re.replace_all(err, "host=$1").to_string();
    cleaned.chars().take(160).collect()
}

/// Collects every encrypted stream of a patched playinfo answer, paired with
/// a usable 16-byte key, in the order the player should try them.
///
/// The upstream switches envelope shape by book genre / tone: the chapter
/// endpoint normally answers `data[].video_model`, while some 智能朗读 voices
/// arrive in the mget-style `data.video_model_datas[].video_model`. Accepting
/// both, tolerating an absent `media_type`, deriving the key from `spade_a`
/// when `key_hex` is missing, and retrying `backup_url` is what keeps an
/// unfamiliar voice from silently falling back to the encrypted direct URL
/// that iOS cannot play.
fn encrypted_audio_candidates(payload: &Value) -> AudioScan {
    let mut models: Vec<Map<String, Value>> = Vec::new();
    match payload.get("data") {
        Some(Value::Array(rows)) => {
            for row in rows {
                if let Some(raw) = row.get("video_model").and_then(|v| v.as_str()) {
                    if let Some(model) = crate::endpoints::video::decode_video_model_str(raw) {
                        models.push(model);
                    }
                }
            }
        }
        Some(Value::Object(data)) => {
            if let Some(rows) = data.get("video_model_datas").and_then(|v| v.as_array()) {
                for row in rows {
                    if let Some(raw) = row.get("video_model").and_then(|v| v.as_str()) {
                        if let Some(model) =
                            crate::endpoints::video::decode_video_model_str(raw)
                        {
                            models.push(model);
                        }
                    }
                }
            }
        }
        _ => {}
    }

    let mut out: Vec<AudioCandidate> = Vec::new();
    let mut seen: std::collections::HashSet<(String, Vec<u8>)> = std::collections::HashSet::new();
    let mut saw_encrypted = false;
    for model in models {
        // Only an explicitly video-flavoured answer is out of scope. TTS
        // voices have been seen without `media_type`, and skipping those was
        // what left 智能朗读 on the encrypted direct URL.
        if model
            .get("media_type")
            .and_then(|v| v.as_str())
            .is_some_and(|kind| kind == "video")
        {
            continue;
        }
        let Some(list) = model.get("video_list").and_then(|v| v.as_array()) else {
            continue;
        };
        for stream in list {
            let Some(item) = stream.as_object() else {
                continue;
            };
            let Some(info) = item.get("encrypt_info").and_then(|v| v.as_object()) else {
                continue;
            };
            if !info
                .get("encrypt")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
            {
                continue;
            }
            // The answer does carry an encrypted stream, even if the details
            // below turn out to be unusable. Remember that.
            saw_encrypted = true;
            // `patch_playinfo_keys` / `patch_encrypted_audio_keys` derive a
            // 16-byte key from `spade_a`. Derive it here too when neither
            // envelope shape carried a `key_hex`, so a voice with an
            // unfamiliar shape is still cached instead of dropped. A stream
            // whose key cannot be derived stays in the list with an empty
            // key: it is then worth caching as plain bytes.
            let key = match info.get("key_hex").and_then(|v| v.as_str()) {
                Some(raw) if raw.len() == 32 => match hex::decode(raw) {
                    Ok(bytes) if bytes.len() == 16 => bytes,
                    _ => Vec::new(),
                },
                _ => {
                    let spade = info.get("spade_a").and_then(|v| v.as_str()).unwrap_or("");
                    let derived = crate::endpoints::video::derive_spade_content_key(spade);
                    if derived.len() == 16 {
                        derived
                    } else {
                        Vec::new()
                    }
                }
            };
            for field in ["main_url", "backup_url"] {
                let Some(url) = item.get(field).and_then(|v| v.as_str()) else {
                    continue;
                };
                if url.is_empty() {
                    continue;
                }
                let marker = (url.to_string(), key.clone());
                if seen.insert(marker) {
                    out.push(AudioCandidate {
                        url: url.to_string(),
                        key: key.clone(),
                    });
                }
            }
        }
    }
    AudioScan {
        candidates: out,
        saw_encrypted,
    }
}

/// Cache entries live in `src_dir`; ids must stay inside one path segment.
/// The tone is part of the id because different voices are different files.
fn audio_cache_id(chapter_id: &str, tone_id: &str) -> String {
    format!("audio_{chapter_id}_{tone_id}")
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// Derives key_hex for every encrypted stream inside an embedded
/// video_model JSON string; returns whether anything changed.
fn patch_model_stream_keys(model: &mut Map<String, Value>) -> bool {
    let Some(list) = model.get_mut("video_list").and_then(|v| v.as_array_mut()) else {
        return false;
    };
    let mut changed = false;
    for item in list.iter_mut() {
        let Some(stream) = item.as_object_mut() else {
            continue;
        };
        let Some(encryption) = stream
            .get_mut("encrypt_info")
            .and_then(|v| v.as_object_mut())
        else {
            continue;
        };
        if !encryption
            .get("encrypt")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            continue;
        }
        let spade_a = encryption
            .get("spade_a")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let key = crate::endpoints::video::derive_spade_content_key(&spade_a);
        if key.len() != 16 {
            continue;
        }
        encryption.insert("key_hex".to_string(), Value::String(hex::encode(&key)));
        changed = true;
    }
    changed
}

/// patchPlayinfoKeys: the playinfo answer nests the streams in
/// data[].video_model (a JSON string).
fn patch_playinfo_keys(v: &mut Value) {
    let Some(root) = v.as_object_mut() else {
        return;
    };
    let Some(rows) = root.get_mut("data").and_then(|d| d.as_array_mut()) else {
        return;
    };
    for row in rows.iter_mut() {
        let Some(entry) = row.as_object_mut() else {
            continue;
        };
        let raw_model = match entry.get("video_model").and_then(|v| v.as_str()) {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => continue,
        };
        let Some(mut model) = crate::endpoints::video::decode_video_model_str(&raw_model) else {
            continue;
        };
        if !patch_model_stream_keys(&mut model) {
            continue;
        }
        if let Ok(patched) = serde_json::to_string(&model) {
            entry.insert("video_model".to_string(), Value::String(patched));
        }
    }
}

/// patchEncryptedAudioKeys: the audio player host nests the streams in
/// data.video_model_datas[].video_model (a JSON string).
fn patch_encrypted_audio_keys(v: &mut Value) {
    let Some(root) = v.as_object_mut() else {
        return;
    };
    let Some(data) = root.get_mut("data").and_then(|d| d.as_object_mut()) else {
        return;
    };
    let Some(rows) = data
        .get_mut("video_model_datas")
        .and_then(|r| r.as_array_mut())
    else {
        return;
    };
    for row in rows.iter_mut() {
        let Some(row_map) = row.as_object_mut() else {
            continue;
        };
        let raw_model = match row_map.get("video_model").and_then(|v| v.as_str()) {
            Some(s) if !s.is_empty() => s.to_string(),
            _ => continue,
        };
        let Some(mut model) = crate::endpoints::video::decode_video_model_str(&raw_model) else {
            continue;
        };
        if !patch_model_stream_keys(&mut model) {
            continue;
        }
        if let Ok(patched) = serde_json::to_string(&model) {
            row_map.insert("video_model".to_string(), Value::String(patched));
        }
    }
}

/// Audio playback: POST /api/v1/audio/play.
const AUDIO_PLAY_HOST: &str = "https://api5-sinfonlineb.novelfm.com";
const AUDIO_PLAY_PATH: &str = "/novelfm/playerapi/video_model/mget/v1";

/// Bounds how many pooled devices a single audio request may try.
const AUDIO_PLAY_ATTEMPTS: usize = 4;

fn handle_play<'a>(ctx: &'a Ctx, params: &'a Params) -> BoxFuture<'a, ApiResult<Value>> {
    Box::pin(async move {
        let item_ids = params.get_str("item_ids");
        let book_id = params.get_str("book_id");
        if item_ids.is_empty() || book_id.is_empty() {
            return Err(ApiError::BadRequest(
                "缺少参数: item_ids / book_id 均为必填".to_string(),
            ));
        }

        let p: Vec<(String, String)> = [
            ("os", "android"),
            ("aid", "3040"),
            ("ssmix", "a"),
            ("manifest_version_code", "632"),
            ("dpi", "440"),
            ("device_brand", "Redmi"),
            ("language", "zh"),
            ("os_api", "35"),
            ("comment_tag_c", "5"),
            ("vip_state", "0"),
            ("host_abi", "arm64-v8a"),
            ("category_style", "1"),
            ("need_personal_recommend", "1"),
            ("rom_version", "miui_V816_OS3.0.1.0.VMRCNXM"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();

        let ids: Vec<String> = item_ids.split(',').map(|s| s.trim().to_string()).collect();
        let body = serde_json::to_vec(&json!({
            "audio_type": 0,
            "bgm_used": 0,
            "book_id": book_id,
            "device_score": 0,
            "item_ids": ids,
            "multi_shift": false,
            "source": "default",
            "tone_id": int_default(&params.get_str("tone_id"), 0),
            "user_select_start_para": 0,
            "user_select_start_para_off": 0,
        }))
        .map_err(|e| ApiError::Internal(format!("marshal audio play body: {e}")))?;

        let spec = UpstreamRequestSpec {
            mode: UpstreamMode::Signed,
            host: AUDIO_PLAY_HOST.to_string(),
            path: AUDIO_PLAY_PATH.to_string(),
            params: p,
            body: Some(body),
            headers: dragon_read_json_headers(),
            ..Default::default()
        };

        let upstream = Upstream::new(ctx.up.clone());
        let mut v = Value::Null;
        let mut last_err: Option<ApiError> = None;
        // 这里用 Signed 模式，根本不经过设备池，所以重试无法换设备（旧注释
        // 写成 pooled devices 是失实的）。保留重试只是为了上游偶发抖动：
        // 网络错误、非 200 响应和截断的 JSON 都属于可能自愈的失败，重试到
        // AUDIO_PLAY_ATTEMPTS 用尽后返回最后一次错误。拿到响应体（哪怕被
        // 上游按设备拒绝）就不再算失败，沿用下面的 code:0 封套。
        for _ in 0..AUDIO_PLAY_ATTEMPTS {
            match upstream.raw(&spec).await.and_then(|raw| raw_json(&raw)) {
                Ok(value) => {
                    v = value;
                    last_err = None;
                    if !audio_play_device_rejected(&v) {
                        break;
                    }
                }
                Err(err) if err.is_retryable() => last_err = Some(err),
                Err(err) => return Err(err),
            }
        }
        if let Some(err) = last_err {
            return Err(err);
        }
        // 桥接封套恒为 code:0 是既定设计（上游封套嵌在 video_info 里，消费方
        // 在那里自查），所以这里不改成错误，只补一条痕迹：全部尝试都被拒绝时
        // 此前没有任何一行日志说明原因。
        if audio_play_device_rejected(&v) {
            log::warn!(
                "audio_play: every attempt was rejected at the body level (401/403/429); \
                 no stream will be available"
            );
        }
        patch_encrypted_audio_keys(&mut v);
        Ok(json!({
            "code": 0,
            "message": "success",
            "video_info": v,
        }))
    })
}

/// A body-level 401/403/429 means the pooled device was rejected.
fn audio_play_device_rejected(v: &Value) -> bool {
    let Some(payload) = v.as_object() else {
        return false;
    };
    let Some(code) = payload.get("code").and_then(|c| c.as_f64()) else {
        return false;
    };
    matches!(code as i64, 401 | 403 | 429)
}

pub fn register(s: &mut Server) {
    s.add_route("audio_book_detail", handle_book_detail);
    s.add_route("audio_chapter_info", handle_chapter_info);
    s.add_route("audio_play", handle_play);
    s.add_route(
        "audio_timeline",
        crate::endpoints::audio_text::handle_timeline,
    );
    s.add_route(
        "audio_timepoint",
        crate::endpoints::audio_text::handle_timepoint,
    );
}

#[cfg(test)]
mod key_vectors {
    //! key_hex golden vectors from the reference test suite.

    use super::*;
    use serde_json::json;

    fn audio_model(spade_a: &str, kid: &str) -> String {
        format!(
            r#"{{"status":10,"media_type":"audio","video_duration":229.96,"video_list":[{{"main_url":"https://cdn/x","backup_url":"https://cdn/y","encrypt_info":{{"encrypt":true,"kid":"{kid}","spade_a":"{spade_a}","encryption_method":"cenc-aes-ctr"}}}}]}}"#
        )
    }

    #[test]
    fn patches_cenc_audio_keys_in_the_audio_play_shape() {
        let model = audio_model(
            "l7wZ+1azG8pUsS7NVIcYzWKCGvlWhCrVV5sa1lWsK+NnqC+2tg==",
            "692e7c06f8818b927094fff40092363a",
        );
        let mut value = json!({
            "data": { "video_model_datas": [ { "item_id": "7579131531361258521", "video_model": model } ] }
        });
        patch_encrypted_audio_keys(&mut value);

        let raw = value["data"]["video_model_datas"][0]["video_model"]
            .as_str()
            .unwrap();
        let parsed: Value = serde_json::from_str(raw).unwrap();
        let enc = &parsed["video_list"][0]["encrypt_info"];
        assert_eq!(enc["key_hex"], "61826b7eceb342a9ad4fd9d7556be625");
        assert_eq!(enc["encryption_method"], "cenc-aes-ctr");
    }

    #[test]
    fn leaves_plain_audio_streams_untouched() {
        let model =
            r#"{"status":10,"media_type":"audio","video_list":[{"main_url":"https://cdn/x"}]}"#;
        let mut value = json!({
            "data": { "video_model_datas": [ { "video_model": model } ] }
        });
        patch_encrypted_audio_keys(&mut value);
        assert_eq!(
            value["data"]["video_model_datas"][0]["video_model"],
            json!(model)
        );
    }

    #[test]
    fn patches_playinfo_keys_in_the_chapter_shape() {
        let model = audio_model(
            "nbwTwF23F/5phBHDb4Qjz3KBC/lBtzrJcLI4y2qGEc9dhRWhoQ==",
            "677752d8f8818bb4b2223c0e00f7a81a",
        );
        let mut value = json!({
            "code": 0,
            "data": [ { "item_id": "7181453438667096588", "video_model": model } ]
        });
        patch_playinfo_keys(&mut value);

        let raw = value["data"][0]["video_model"].as_str().unwrap();
        let parsed: Value = serde_json::from_str(raw).unwrap();
        assert_eq!(
            parsed["video_list"][0]["encrypt_info"]["key_hex"],
            "0f7a32fda0f04388ba27cf1d0a95b024"
        );
    }

    #[test]
    fn finds_candidates_in_the_mget_envelope_shape() {
        // 智能朗读的章节答案用的是 mget 形状（data.video_model_datas[]）。
        // key 必须能从 spade_a 派生出来，否则核心与 Dart 两侧都会认为这一章
        // 没有可播的流 —— 这正是智能朗读一直播不了的原因。
        let model = audio_model(
            "l7wZ+1azG8pUsS7NVIcYzWKCGvlWhCrVV5sa1lWsK+NnqC+2tg==",
            "692e7c06f8818b927094fff40092363a",
        );
        let mut value = json!({
            "code": 0,
            "data": { "video_model_datas": [ { "item_id": "1", "video_model": model } ] }
        });
        patch_encrypted_audio_keys(&mut value);
        let scan = encrypted_audio_candidates(&value);
        assert!(scan.saw_encrypted, "the answer carries an encrypted stream");
        let candidates = scan.candidates;
        assert_eq!(candidates.len(), 2, "main_url and backup_url");
        assert_eq!(
            candidates[0].key,
            hex::decode("61826b7eceb342a9ad4fd9d7556be625").expect("key")
        );
    }

    #[test]
    fn finds_candidates_in_the_chapter_envelope_shape() {
        let model = audio_model(
            "nbwTwF23F/5phBHDb4Qjz3KBC/lBtzrJcLI4y2qGEc9dhRWhoQ==",
            "677752d8f8818bb4b2223c0e00f7a81a",
        );
        let mut value = json!({
            "code": 0,
            "data": [ { "item_id": "1", "video_model": model } ]
        });
        patch_playinfo_keys(&mut value);
        let scan = encrypted_audio_candidates(&value);
        assert!(scan.saw_encrypted, "the answer carries an encrypted stream");
        let candidates = scan.candidates;
        assert_eq!(candidates.len(), 2, "main_url and backup_url");
        assert_eq!(
            candidates[0].key,
            hex::decode("0f7a32fda0f04388ba27cf1d0a95b024").expect("key")
        );
    }
}
