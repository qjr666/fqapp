//! Pairing for LAN sync (P4 of `docs/lan-sync-design.md`, §M2).
//!
//! A host shows a short-lived six-digit code. A peer posts it together with
//! its device identity and receives a long-lived secret. Secrets are kept in
//! `runtime_dir/sync-pairs.json` so restarting the core does not unpair
//! devices, and the host can revoke them one by one.
//!
//! `POST /api/v1/sync/pair` is the *only* sync route reachable without the
//! per-launch capability: the code in the body is the credential. Every other
//! sync route still needs the capability or an issued secret — see the gate in
//! `server::handle_request`. Like the sync inbox, this file lives one level
//! above `src/` so `/src/*` can never serve it.

use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::dispatch::{Request, Response};

pub const PAIR_PATH: &str = "/api/v1/sync/pair";
pub const PAIR_CODE_PATH: &str = "/api/v1/sync/pair/code";
pub const HOSTS_PATH: &str = "/api/v1/sync/hosts";
pub const REVOKE_PATH: &str = "/api/v1/sync/hosts/revoke";

/// Pairing bodies are tiny: a code plus a device identity.
pub const PAIR_REQUEST_BODY_LIMIT: usize = 4 * 1024;

const CODE_TTL_MS: u64 = 60_000;
const CODE_ATTEMPTS: u32 = 5;
const MAX_DEVICES: usize = 16;
const MAX_DEVICE_FIELD: usize = 128;
const SECRET_BYTES: usize = 32;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairedDevice {
    pub id: String,
    pub name: String,
    pub platform: String,
    pub secret: String,
    #[serde(rename = "pairedAt")]
    pub paired_at: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct PendingCode {
    code: String,
    #[serde(rename = "expiresAt")]
    expires_at: u64,
    attempts: u32,
}

#[derive(Default, Serialize, Deserialize)]
struct PairFile {
    devices: Vec<PairedDevice>,
}

#[derive(Default)]
struct PairStore {
    pending: Option<PendingCode>,
    devices: Vec<PairedDevice>,
    hydrated: bool,
}

static STORE: OnceLock<Mutex<PairStore>> = OnceLock::new();

fn store() -> &'static Mutex<PairStore> {
    STORE.get_or_init(|| Mutex::new(PairStore::default()))
}

fn pairs_path(runtime_dir: &Path) -> std::path::PathBuf {
    runtime_dir.join("sync-pairs.json")
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Loads issued secrets once per process. `serve` calls this when the
/// listener starts, so the HTTP capability gate can answer before any sync
/// handler has run in this process.
pub async fn hydrate(runtime_dir: &Path) {
    if store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .hydrated
    {
        return;
    }
    let bytes = tokio::fs::read(pairs_path(runtime_dir))
        .await
        .unwrap_or_default();
    let restored = serde_json::from_slice::<PairFile>(&bytes).unwrap_or_default();
    let mut state = store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    state.hydrated = true;
    if state.devices.is_empty() {
        state.devices = restored
            .devices
            .into_iter()
            .filter(|device| !device.id.is_empty() && device.secret.len() == SECRET_BYTES * 2)
            .take(MAX_DEVICES)
            .collect();
    }
}

/// Atomic write through a temporary name, matching the sync inbox.
async fn persist(runtime_dir: &Path, devices: &[PairedDevice]) {
    let Ok(bytes) = serde_json::to_vec(&PairFile {
        devices: devices.to_vec(),
    }) else {
        return;
    };
    if std::fs::create_dir_all(runtime_dir).is_err() {
        return;
    }
    let tmp = runtime_dir.join("sync-pairs.json.tmp");
    if tokio::fs::write(&tmp, &bytes).await.is_ok() {
        let _ = tokio::fs::rename(&tmp, pairs_path(runtime_dir)).await;
    }
}

/// Timing-independent comparison. Secrets are 64 hex characters and the list
/// is tiny, but a plain `==` would still leak prefix matches on a shared LAN.
fn constant_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (left, right) in a.bytes().zip(b.bytes()) {
        diff |= left ^ right;
    }
    diff == 0
}

/// Whether `secret` was issued to a still-paired device. Called by the HTTP
/// gate for sync routes only; pure in-memory so it stays cheap.
pub fn is_authorized(secret: &str) -> bool {
    if secret.len() != SECRET_BYTES * 2 {
        return false;
    }
    let state = store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    state
        .devices
        .iter()
        .any(|device| constant_eq(&device.secret, secret))
}

fn failure(status: u16, message: &str) -> Response {
    let mut response = Response::json(status, &json!({ "success": false, "error": message }));
    response
        .headers
        .push(("cache-control".into(), "no-store".into()));
    response
}

fn method_not_allowed(allow: &str) -> Response {
    let mut response = failure(405, "method not allowed");
    response.headers.push(("allow".into(), allow.into()));
    response
}

fn body_json(req: &Request) -> Result<Value, (u16, &'static str)> {
    if req.body.len() > PAIR_REQUEST_BODY_LIMIT {
        return Err((413, "pairing payload too large"));
    }
    serde_json::from_slice(&req.body).map_err(|_| (400, "invalid pairing request"))
}

fn device_field(value: Option<&Value>) -> Result<String, (u16, &'static str)> {
    let Some(text) = value.and_then(Value::as_str) else {
        return Err((400, "invalid device"));
    };
    let text = text.trim();
    if text.is_empty() || text.len() > MAX_DEVICE_FIELD {
        return Err((400, "invalid device"));
    }
    Ok(text.to_string())
}

fn random_hex(bytes: usize) -> Result<String, (u16, &'static str)> {
    let mut buffer = vec![0u8; bytes];
    rand::rngs::OsRng
        .try_fill_bytes(&mut buffer)
        .map_err(|_| (500, "random source unavailable"))?;
    Ok(hex::encode(buffer))
}

fn new_code() -> Result<String, (u16, &'static str)> {
    let mut buffer = [0u8; 4];
    rand::rngs::OsRng
        .try_fill_bytes(&mut buffer)
        .map_err(|_| (500, "random source unavailable"))?;
    Ok(format!("{:06}", u32::from_be_bytes(buffer) % 1_000_000))
}

fn create_code() -> Result<Response, (u16, &'static str)> {
    let code = new_code()?;
    let expires_at = now_ms() + CODE_TTL_MS;
    {
        let mut state = store()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.pending = Some(PendingCode {
            code: code.clone(),
            expires_at,
            attempts: 0,
        });
    }
    Ok(Response::json(
        200,
        &json!({
            "success": true,
            "code": code,
            "expiresAt": expires_at,
            "ttlSeconds": CODE_TTL_MS / 1000,
        }),
    ))
}

fn list_hosts() -> Response {
    let devices: Vec<Value> = {
        let state = store()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state
            .devices
            .iter()
            .map(|device| {
                json!({
                    "id": device.id,
                    "name": device.name,
                    "platform": device.platform,
                    "pairedAt": device.paired_at,
                })
            })
            .collect()
    };
    // Deliberately no `secret`: the host list is rendered in the UI.
    Response::json(200, &json!({ "success": true, "devices": devices }))
}

async fn redeem(req: &Request, runtime_dir: &Path) -> Result<Response, (u16, &'static str)> {
    let body = body_json(req)?;
    let code = body
        .get("code")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if code.len() != 6 || !code.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err((400, "invalid pairing code"));
    }
    let device = body.get("device");
    let id = device_field(device.and_then(|value| value.get("id")))?;
    let name = device_field(device.and_then(|value| value.get("name")))?;
    let platform = device_field(device.and_then(|value| value.get("platform")))?;

    let now = now_ms();
    // Generate the secret before touching the store: a broken random source
    // must not consume the one-time code.
    let secret = random_hex(SECRET_BYTES)?;
    // Validate, consume and enroll under a single lock so two peers cannot
    // both redeem the same code.
    let snapshot = {
        let mut state = store()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.devices.iter().all(|d| d.id != id) && state.devices.len() >= MAX_DEVICES {
            return Err((409, "too many paired devices"));
        }
        let Some(pending) = state.pending.take() else {
            return Err((400, "no pairing code is active"));
        };
        if now >= pending.expires_at {
            return Err((410, "pairing code expired"));
        }
        if pending.attempts >= CODE_ATTEMPTS {
            return Err((429, "too many pairing attempts"));
        }
        if !constant_eq(&pending.code, code) {
            // A wrong guess burns one attempt but keeps the code alive until
            // the budget is exhausted.
            let attempts = pending.attempts + 1;
            if attempts < CODE_ATTEMPTS {
                state.pending = Some(PendingCode {
                    attempts,
                    ..pending
                });
            }
            return Err((400, "invalid pairing code"));
        }
        // A fresh secret replaces any earlier pairing for the same device id,
        // so re-pairing a lost phone cannot leave a stale credential behind.
        state.devices.retain(|device| device.id != id);
        state.devices.push(PairedDevice {
            id: id.clone(),
            name: name.clone(),
            platform: platform.clone(),
            secret: secret.clone(),
            paired_at: now,
        });
        state.devices.clone()
    };
    persist(runtime_dir, &snapshot).await;
    Ok(Response::json(
        200,
        &json!({
            "success": true,
            "secret": secret,
            "device": {
                "id": id,
                "name": name,
                "platform": platform,
                "pairedAt": now,
            },
        }),
    ))
}

async fn revoke(req: &Request, runtime_dir: &Path) -> Result<Response, (u16, &'static str)> {
    let body = body_json(req)?;
    let id = body
        .get("deviceId")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if id.is_empty() || id.len() > MAX_DEVICE_FIELD {
        return Err((400, "invalid device"));
    }
    let snapshot = {
        let mut state = store()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        state.devices.retain(|device| device.id != id);
        state.devices.clone()
    };
    persist(runtime_dir, &snapshot).await;
    Ok(Response::json(200, &json!({ "success": true })))
}

/// Returns `None` for every sync route owned by `endpoints::sync`.
pub async fn handle(req: &Request, runtime_dir: &Path) -> Option<Response> {
    let path = req.path.trim_end_matches('/');
    if !matches!(path, PAIR_PATH | PAIR_CODE_PATH | HOSTS_PATH | REVOKE_PATH) {
        return None;
    }
    hydrate(runtime_dir).await;
    let method = req.method.as_str();
    let response = match (path, method) {
        (PAIR_CODE_PATH, m) if m.eq_ignore_ascii_case("POST") => match create_code() {
            Ok(response) => response,
            Err((status, message)) => failure(status, message),
        },
        (PAIR_CODE_PATH, _) => method_not_allowed("POST"),
        (PAIR_PATH, m) if m.eq_ignore_ascii_case("POST") => match redeem(req, runtime_dir).await {
            Ok(response) => response,
            Err((status, message)) => failure(status, message),
        },
        (PAIR_PATH, _) => method_not_allowed("POST"),
        (HOSTS_PATH, m) if m.eq_ignore_ascii_case("GET") => list_hosts(),
        (HOSTS_PATH, _) => method_not_allowed("GET"),
        (REVOKE_PATH, m) if m.eq_ignore_ascii_case("POST") => {
            match revoke(req, runtime_dir).await {
                Ok(response) => response,
                Err((status, message)) => failure(status, message),
            }
        }
        (REVOKE_PATH, _) => method_not_allowed("POST"),
        _ => failure(404, "unknown pairing route"),
    };
    Some(response)
}

/// Only for tests: forget the in-process state so a fresh `hydrate` reads the
/// persisted file again, as a restarted core would.
#[cfg(test)]
fn reset_for_test() {
    *store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = PairStore::default();
}

#[cfg(test)]
fn expire_pending_for_test() {
    let mut state = store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(pending) = state.pending.as_mut() {
        pending.expires_at = 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pair store is process-wide; tests must not interleave.
    static TEST_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

    async fn setup(tag: &str) -> (tokio::sync::MutexGuard<'static, ()>, std::path::PathBuf) {
        let guard = TEST_LOCK
            .get_or_init(|| tokio::sync::Mutex::new(()))
            .lock()
            .await;
        reset_for_test();
        let dir = std::env::temp_dir().join(format!("fqapp-pair-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let _ = std::fs::remove_file(pairs_path(&dir));
        hydrate(&dir).await;
        (guard, dir)
    }

    fn request(method: &str, path: &str) -> Request {
        Request {
            method: method.into(),
            path: path.into(),
            query: String::new(),
            body: Vec::new(),
            headers: Vec::new(),
        }
    }

    fn with_json(mut req: Request, value: Value) -> Request {
        req.body = serde_json::to_vec(&value).unwrap();
        req
    }

    fn code_request() -> Request {
        request("POST", PAIR_CODE_PATH)
    }

    fn pair_request(code: &str, id: &str) -> Request {
        with_json(
            request("POST", PAIR_PATH),
            json!({
                "code": code,
                "device": { "id": id, "name": "peer phone", "platform": "android" },
            }),
        )
    }

    async fn body_json(response: Response) -> Value {
        let bytes = response.into_bytes().await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    async fn issue_code(dir: &Path) -> String {
        let body = body_json(handle(&code_request(), dir).await.unwrap()).await;
        assert_eq!(body["success"], true);
        let code = body["code"].as_str().unwrap();
        assert_eq!(code.len(), 6);
        assert!(code.bytes().all(|byte| byte.is_ascii_digit()));
        code.to_string()
    }

    #[tokio::test]
    async fn a_code_is_exchanged_once_for_a_secret_and_then_rejected() {
        let (_guard, dir) = setup("redeem").await;
        let code = issue_code(&dir).await;

        let issued = body_json(
            handle(&pair_request(&code, "device-b"), &dir)
                .await
                .unwrap(),
        )
        .await;
        let secret = issued["secret"].as_str().expect("secret").to_string();
        assert_eq!(secret.len(), SECRET_BYTES * 2);
        assert!(is_authorized(&secret));
        assert_eq!(issued["device"]["id"], "device-b");

        // Single-use: the same code cannot enroll a second device.
        let reused = handle(&pair_request(&code, "device-c"), &dir)
            .await
            .unwrap();
        assert_eq!(reused.status, 400);
        assert!(!is_authorized("0".repeat(SECRET_BYTES * 2).as_str()));
    }

    #[tokio::test]
    async fn wrong_codes_burn_the_attempt_budget() {
        let (_guard, dir) = setup("attempts").await;
        let code = issue_code(&dir).await;
        // Never guess the real code by accident (it is random six digits).
        let wrong_code = if code == "000000" { "111111" } else { "000000" };
        for _ in 0..CODE_ATTEMPTS {
            let wrong = handle(&pair_request(wrong_code, "device-b"), &dir)
                .await
                .unwrap();
            assert_eq!(wrong.status, 400);
        }
        // The budget is exhausted: the code is dropped, so even the right one
        // can no longer be redeemed.
        let exhausted = handle(&pair_request(&code, "device-b"), &dir)
            .await
            .unwrap();
        assert_eq!(exhausted.status, 400);
        assert!(!is_authorized(&"a".repeat(SECRET_BYTES * 2)));
    }

    #[tokio::test]
    async fn an_expired_code_is_refused() {
        let (_guard, dir) = setup("expired").await;
        let code = issue_code(&dir).await;
        expire_pending_for_test();
        let expired = handle(&pair_request(&code, "device-b"), &dir)
            .await
            .unwrap();
        assert_eq!(expired.status, 410);
    }

    #[tokio::test]
    async fn hosts_hide_secrets_and_revocation_invalidates_them() {
        let (_guard, dir) = setup("revoke").await;
        let code = issue_code(&dir).await;
        let issued = body_json(
            handle(&pair_request(&code, "device-b"), &dir)
                .await
                .unwrap(),
        )
        .await;
        let secret = issued["secret"].as_str().unwrap().to_string();

        let hosts = body_json(handle(&request("GET", HOSTS_PATH), &dir).await.unwrap()).await;
        assert_eq!(hosts["devices"].as_array().unwrap().len(), 1);
        assert!(hosts["devices"][0].get("secret").is_none());

        let revoked = handle(
            &with_json(
                request("POST", REVOKE_PATH),
                json!({ "deviceId": "device-b" }),
            ),
            &dir,
        )
        .await
        .unwrap();
        assert_eq!(revoked.status, 200);
        assert!(!is_authorized(&secret));
    }

    #[tokio::test]
    async fn issued_secrets_survive_a_core_restart() {
        let (_guard, dir) = setup("persist").await;
        let code = issue_code(&dir).await;
        let issued = body_json(
            handle(&pair_request(&code, "device-b"), &dir)
                .await
                .unwrap(),
        )
        .await;
        let secret = issued["secret"].as_str().unwrap().to_string();

        reset_for_test();
        assert!(!is_authorized(&secret));
        hydrate(&dir).await;
        assert!(is_authorized(&secret));

        let hosts = body_json(handle(&request("GET", HOSTS_PATH), &dir).await.unwrap()).await;
        assert_eq!(hosts["devices"][0]["id"], "device-b");
    }

    #[tokio::test]
    async fn malformed_requests_and_wrong_methods_are_refused() {
        let (_guard, dir) = setup("malformed").await;
        assert_eq!(
            handle(&request("GET", PAIR_PATH), &dir)
                .await
                .unwrap()
                .status,
            405
        );
        assert_eq!(
            handle(&pair_request("abc", "device-b"), &dir)
                .await
                .unwrap()
                .status,
            400
        );
        assert_eq!(
            handle(&with_json(request("POST", PAIR_PATH), json!({})), &dir)
                .await
                .unwrap()
                .status,
            400
        );
        assert!(handle(&request("GET", "/api/v1/sync/snapshot"), &dir)
            .await
            .is_none());
    }
}
