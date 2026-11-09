//! LAN sync transport (P2 of `docs/lan-sync-design.md`).
//!
//! The Rust core is a dumb transport plus a small staging area: it knows
//! nothing about Hive, books or progress records. Dart owns the snapshot
//! (`LibraryBackup.encode()`) and the merge; all the core does is hold the
//! device's latest snapshot for a peer to read, and hold the last snapshot a
//! peer pushed for Dart to pick up and merge.
//!
//! The envelope is deliberately dumb too — `format`/`version`/`device`/
//! `sentAt`/`backup`. The `backup` value is passed through untouched so the
//! export/import path and the LAN path share exactly one decoder.
//!
//! Every `/api/v1/sync/*` route requires the loopback capability (see
//! `dispatch::requires_capability`): in Lan mode read routes are otherwise
//! open to the whole subnet, and a reading history is private. The in-process
//! FFI transport does not go through the capability check, so the app on this
//! device can always reach its own staging area.

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::dispatch::{Request, Response};

/// All sync routes live under this prefix. `dispatch` hands the whole prefix
/// to [`handle`] instead of registering route names in `router.rs`, because
/// these endpoints need the request method and body, which the name-based
/// `Handler` signature does not carry.
pub const SYNC_PATH_PREFIX: &str = "/api/v1/sync/";

/// A snapshot is a `LibraryBackup.encode()` payload (16 MB cap) wrapped in a
/// small envelope, so the same limit applies here.
pub const SYNC_REQUEST_BODY_LIMIT: usize = 16 * 1024 * 1024;

const ENVELOPE_FORMAT: &str = "fqapp.sync-envelope";
const ENVELOPE_VERSION: u64 = 1;
const MAX_DEVICE_FIELD: usize = 128;
/// Sanity bound: ~year 2255 in milliseconds.
const MAX_SENT_AT: u64 = 9_000_000_000_000_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncDevice {
    pub id: String,
    pub name: String,
    pub platform: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncEnvelope {
    pub format: String,
    pub version: u64,
    pub device: SyncDevice,
    #[serde(rename = "sentAt")]
    pub sent_at: u64,
    /// The `LibraryBackup.encode()` JSON, opaque to the core.
    pub backup: Value,
}

impl SyncEnvelope {
    /// Shape checks only. The business validation of `backup` belongs to
    /// `LibraryBackup.decode()` on the Dart side; the core must not grow a
    /// second, drifting copy of it.
    fn validate(&self) -> Result<(), &'static str> {
        if self.format != ENVELOPE_FORMAT || self.version != ENVELOPE_VERSION {
            return Err("unsupported sync envelope");
        }
        if self.device.id.is_empty()
            || self.device.id.len() > MAX_DEVICE_FIELD
            || self.device.name.len() > MAX_DEVICE_FIELD
            || self.device.platform.len() > MAX_DEVICE_FIELD
        {
            return Err("invalid sync device");
        }
        if self.sent_at == 0 || self.sent_at > MAX_SENT_AT {
            return Err("invalid sync timestamp");
        }
        if !self.backup.is_object()
            || !self.backup.get("version").is_some()
            || !self.backup.get("history").is_some()
            || !self.backup.get("shelf").is_some()
        {
            return Err("invalid sync backup");
        }
        Ok(())
    }
}

#[derive(Default)]
struct SyncStore {
    /// This device's latest snapshot, served to peers.
    local: Option<SyncEnvelope>,
    etag: String,
    /// The last snapshot a peer pushed, waiting for Dart to merge.
    inbox: Option<SyncEnvelope>,
    /// Whether the on-disk inbox has been folded into this process yet.
    hydrated: bool,
}

static STORE: OnceLock<Mutex<SyncStore>> = OnceLock::new();

fn store() -> &'static Mutex<SyncStore> {
    STORE.get_or_init(|| Mutex::new(SyncStore::default()))
}

/// A test helper is deliberately the only way to clear the staging area:
/// production state must survive a Dart-side hot restart of the UI.
#[cfg(test)]
fn reset_store() {
    *store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = SyncStore::default();
}

fn inbox_path(runtime_dir: &Path) -> std::path::PathBuf {
    runtime_dir.join("sync-inbox.json")
}

/// Folds a staging file left by a previous core run into this process.
///
/// The file lives in the runtime directory, one level above `src/`: anything
/// under `src/` is served by `/src/*` and must never expose reading history.
async fn hydrate(runtime_dir: &Path) {
    let already = store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .hydrated;
    if already {
        return;
    }
    let bytes = tokio::fs::read(inbox_path(runtime_dir))
        .await
        .unwrap_or_default();
    let restored = serde_json::from_slice::<SyncEnvelope>(&bytes)
        .ok()
        .filter(|envelope| envelope.validate().is_ok());
    let mut state = store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    state.hydrated = true;
    if state.inbox.is_none() {
        state.inbox = restored;
    }
}

/// Writes the staging file through a temporary name so a crash mid-write
/// cannot leave a half envelope behind.
async fn persist_inbox(runtime_dir: &Path, envelope: Option<&SyncEnvelope>) {
    if std::fs::create_dir_all(runtime_dir).is_err() {
        return;
    }
    let path = inbox_path(runtime_dir);
    match envelope {
        Some(envelope) => {
            let Ok(bytes) = serde_json::to_vec(envelope) else {
                return;
            };
            let tmp = runtime_dir.join("sync-inbox.json.tmp");
            if tokio::fs::write(&tmp, &bytes).await.is_ok() {
                let _ = tokio::fs::rename(&tmp, &path).await;
            }
        }
        None => {
            let _ = tokio::fs::remove_file(&path).await;
        }
    }
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

/// Returns `(status, message)` instead of a whole `Response`: the error
/// variant stays small, and the caller turns it into the no-store failure.
fn parse_envelope(req: &Request) -> Result<SyncEnvelope, (u16, &'static str)> {
    if req.body.len() > SYNC_REQUEST_BODY_LIMIT {
        return Err((413, "sync payload too large"));
    }
    let envelope: SyncEnvelope =
        serde_json::from_slice(&req.body).map_err(|_| (400, "invalid sync envelope"))?;
    envelope.validate().map_err(|message| (400, message))?;
    Ok(envelope)
}

fn etag_for(envelope: &SyncEnvelope) -> String {
    let bytes = serde_json::to_vec(envelope).unwrap_or_default();
    hex::encode(Sha256::digest(&bytes))
}

/// Serves the four staging routes. `runtime_dir` is the core's runtime
/// directory (the parent of `src/`), supplied by `dispatch`.
pub async fn handle(req: &Request, runtime_dir: &Path) -> Response {
    // Pairing owns four routes under the same prefix. Answer those first so
    // the one-time code exchange stays in one module; the staging area below
    // keeps knowing nothing about pairing.
    if let Some(response) = crate::endpoints::sync_pair::handle(req, runtime_dir).await {
        return response;
    }
    hydrate(runtime_dir).await;
    let path = req.path.trim_end_matches('/');
    let Some(tail) = path.strip_prefix(SYNC_PATH_PREFIX) else {
        return failure(404, "unknown sync route");
    };
    match (tail, req.method.as_str()) {
        // Dart publishes this device's snapshot before a peer can pull it.
        // The design's sequence diagram calls this the "local channel write".
        ("local", method) if method.eq_ignore_ascii_case("POST") => {
            let envelope = match parse_envelope(req) {
                Ok(envelope) => envelope,
                Err((status, message)) => return failure(status, message),
            };
            let etag = etag_for(&envelope);
            {
                let mut state = store()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                state.local = Some(envelope);
                state.etag = etag.clone();
            }
            Response::json(200, &json!({ "success": true, "etag": etag }))
        }
        ("local", _) => method_not_allowed("POST"),

        ("snapshot", method) if method.eq_ignore_ascii_case("GET") => {
            let (envelope, etag) = {
                let state = store()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                (state.local.clone(), state.etag.clone())
            };
            let tag = format!("\"{etag}\"");
            if !etag.is_empty()
                && req
                    .header("if-none-match")
                    .is_some_and(|value| value.trim() == tag || value.trim() == etag)
            {
                let mut response = Response::text(304, "application/json", Vec::new());
                response.headers.push(("etag".into(), tag));
                return response;
            }
            let mut response = Response::json(
                200,
                &json!({ "success": true, "envelope": envelope, "etag": etag }),
            );
            response.headers.push(("etag".into(), tag));
            response
        }
        // A peer pushes its snapshot into this device's inbox. Only the newest
        // one is kept: merging twice is harmless, but an old snapshot arriving
        // after a new one must not replace it.
        ("snapshot", method) if method.eq_ignore_ascii_case("POST") => {
            let envelope = match parse_envelope(req) {
                Ok(envelope) => envelope,
                Err((status, message)) => return failure(status, message),
            };
            {
                let mut state = store()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                if state
                    .inbox
                    .as_ref()
                    .is_none_or(|old| envelope.sent_at >= old.sent_at)
                {
                    state.inbox = Some(envelope.clone());
                }
            }
            persist_inbox(runtime_dir, Some(&envelope)).await;
            Response::text(204, "application/json", Vec::new())
        }
        ("snapshot", _) => method_not_allowed("GET, POST"),

        // Dart polls this, merges what it receives, and confirms by taking
        // it: a second GET returns an empty envelope.
        ("inbox", method) if method.eq_ignore_ascii_case("GET") => {
            let envelope = {
                let mut state = store()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                state.inbox.take()
            };
            persist_inbox(runtime_dir, None).await;
            Response::json(200, &json!({ "success": true, "envelope": envelope }))
        }
        ("inbox", _) => method_not_allowed("GET"),
        _ => failure(404, "unknown sync route"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The staging area is process-wide; tests must not interleave. An async
    /// lock is used so the guard may be held across the awaits below.
    static TEST_LOCK: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();

    fn test_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("fqapp-sync-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    async fn setup(tag: &str) -> (tokio::sync::MutexGuard<'static, ()>, std::path::PathBuf) {
        let guard = TEST_LOCK
            .get_or_init(|| tokio::sync::Mutex::new(()))
            .lock()
            .await;
        reset_store();
        let dir = test_dir(tag);
        let _ = std::fs::remove_file(inbox_path(&dir));
        (guard, dir)
    }

    fn envelope(sent_at: u64) -> SyncEnvelope {
        SyncEnvelope {
            format: ENVELOPE_FORMAT.into(),
            version: ENVELOPE_VERSION,
            device: SyncDevice {
                id: "device-a".into(),
                name: "phone".into(),
                platform: "ios".into(),
            },
            sent_at,
            backup: json!({
                "format": "fqapp.library-backup",
                "version": 1,
                "createdAt": 1,
                "shelf": [],
                "history": {"book-1": {"time": sent_at}},
                "watched": [],
                "excludedLocalRecords": []
            }),
        }
    }

    fn request(method: &str, tail: &str) -> Request {
        Request {
            method: method.into(),
            path: format!("{SYNC_PATH_PREFIX}{tail}"),
            query: String::new(),
            body: Vec::new(),
            headers: Vec::new(),
        }
    }

    fn with_body(mut req: Request, envelope: &SyncEnvelope) -> Request {
        req.body = serde_json::to_vec(envelope).unwrap();
        req
    }

    async fn body_json(response: Response) -> Value {
        let bytes = response.into_bytes().await.unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[tokio::test]
    async fn an_empty_device_serves_a_null_snapshot() {
        let (_guard, dir) = setup("empty").await;
        let response = handle(&request("GET", "snapshot"), &dir).await;
        assert_eq!(response.status, 200);
        let body = body_json(response).await;
        assert_eq!(body["success"], true);
        assert!(body["envelope"].is_null());
        assert_eq!(body["etag"], "");
    }

    #[tokio::test]
    async fn publishing_a_local_snapshot_sets_an_etag_and_answers_304() {
        let (_guard, dir) = setup("etag").await;
        let published = handle(&with_body(request("POST", "local"), &envelope(1000)), &dir).await;
        assert_eq!(published.status, 200);
        let etag = body_json(published).await["etag"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(!etag.is_empty());

        let mut conditional = request("GET", "snapshot");
        conditional
            .headers
            .push(("if-none-match".into(), format!("\"{etag}\"")));
        let not_modified = handle(&conditional, &dir).await;
        assert_eq!(not_modified.status, 304);

        let served = handle(&request("GET", "snapshot"), &dir).await;
        let body = body_json(served).await;
        assert_eq!(body["etag"], etag);
        assert_eq!(body["envelope"]["sentAt"], 1000);
    }

    #[tokio::test]
    async fn a_pushed_snapshot_is_taken_once_and_clears_the_staging_file() {
        let (_guard, dir) = setup("inbox").await;
        let pushed = handle(
            &with_body(request("POST", "snapshot"), &envelope(2000)),
            &dir,
        )
        .await;
        assert_eq!(pushed.status, 204);
        assert!(inbox_path(&dir).exists(), "inbox must be persisted to disk");

        let first = body_json(handle(&request("GET", "inbox"), &dir).await).await;
        assert_eq!(first["envelope"]["sentAt"], 2000);
        let second = body_json(handle(&request("GET", "inbox"), &dir).await).await;
        assert!(second["envelope"].is_null());
        assert!(
            !inbox_path(&dir).exists(),
            "taking the inbox clears the file"
        );
    }

    #[tokio::test]
    async fn an_older_snapshot_does_not_replace_a_newer_inbox_entry() {
        let (_guard, dir) = setup("ordering").await;
        let _ = handle(
            &with_body(request("POST", "snapshot"), &envelope(3000)),
            &dir,
        )
        .await;
        let _ = handle(
            &with_body(request("POST", "snapshot"), &envelope(1000)),
            &dir,
        )
        .await;
        let taken = body_json(handle(&request("GET", "inbox"), &dir).await).await;
        assert_eq!(taken["envelope"]["sentAt"], 3000);
    }

    #[tokio::test]
    async fn a_staging_file_survives_a_core_restart() {
        let (_guard, dir) = setup("restart").await;
        let _ = handle(
            &with_body(request("POST", "snapshot"), &envelope(4000)),
            &dir,
        )
        .await;
        reset_store();
        let taken = body_json(handle(&request("GET", "inbox"), &dir).await).await;
        assert_eq!(taken["envelope"]["sentAt"], 4000);
    }

    #[tokio::test]
    async fn malformed_envelopes_and_wrong_methods_are_rejected() {
        let (_guard, dir) = setup("reject").await;
        let bad = envelope(5000);
        let mut wrong_format = bad.clone();
        wrong_format.format = "something.else".into();
        let rejected = handle(&with_body(request("POST", "local"), &wrong_format), &dir).await;
        assert_eq!(rejected.status, 400);

        let mut broken_backup = bad;
        broken_backup.backup = json!({ "unexpected": true });
        let rejected = handle(&with_body(request("POST", "local"), &broken_backup), &dir).await;
        assert_eq!(rejected.status, 400);

        let wrong_method = handle(&request("GET", "local"), &dir).await;
        assert_eq!(wrong_method.status, 405);
        assert!(wrong_method
            .headers
            .iter()
            .any(|(key, value)| key == "allow" && value == "POST"));
        assert_eq!(handle(&request("GET", "unknown"), &dir).await.status, 404);
    }

    #[test]
    fn sync_routes_require_the_capability_and_retain_the_body() {
        for path in [
            "/api/v1/sync/local",
            "/api/v1/sync/snapshot",
            "/api/v1/sync/inbox",
        ] {
            assert!(
                crate::dispatch::requires_capability(path),
                "{path} must be behind the capability"
            );
        }
        // P4: the code exchange is the single unauthenticated sync route;
        // everything it grants access to stays private.
        assert!(!crate::dispatch::requires_capability(
            crate::endpoints::sync_pair::PAIR_PATH
        ));
        assert!(crate::dispatch::requires_capability(
            crate::endpoints::sync_pair::HOSTS_PATH
        ));
        assert_eq!(
            crate::dispatch::request_body_limit(crate::endpoints::sync_pair::PAIR_PATH),
            Some(crate::endpoints::sync_pair::PAIR_REQUEST_BODY_LIMIT)
        );
        assert_eq!(
            crate::dispatch::request_body_limit("/api/v1/sync/local"),
            Some(SYNC_REQUEST_BODY_LIMIT)
        );
        assert_eq!(
            crate::dispatch::request_body_limit("/api/v1/sync/snapshot"),
            Some(SYNC_REQUEST_BODY_LIMIT)
        );
        assert_eq!(
            crate::dispatch::request_body_limit("/api/v1/sync/inbox"),
            None
        );
    }
}
