//! LAN sync staging over the real HTTP adapter (P2 acceptance).
//!
//! The listener runs in `Lan` mode: a second device reaches exactly these
//! routes, and must not reach the reading history without the capability.
//! The FFI path is intentionally not exercised here — it has no headers and
//! no capability gate, which is correct for the app on this device.

mod common;

use common::{build_server, pool_json, start_listener, TempDir};
use fqapi_core::server::ListenMode;
use serde_json::{json, Value};

fn envelope(sent_at: u64, device: &str) -> Value {
    json!({
        "format": "fqapp.sync-envelope",
        "version": 1,
        "device": { "id": device, "name": "peer phone", "platform": "android" },
        "sentAt": sent_at,
        "backup": {
            "format": "fqapp.library-backup",
            "version": 1,
            "createdAt": sent_at,
            "shelf": [],
            "history": { "book-1": { "time": sent_at } },
            "watched": [],
            "excludedLocalRecords": []
        }
    })
}

#[tokio::test]
async fn a_lan_peer_needs_the_capability_and_can_round_trip_a_snapshot() {
    let dir = TempDir::new("sync-lan-transport");
    let server = build_server(&dir, None, &[], &[], &pool_json(2)).await;
    let lb = start_listener(server, ListenMode::Lan).await;
    let client = reqwest::Client::new();

    // 1. An unpaired device on the same network is refused, for GET too.
    let refused = client
        .get(lb.bare_url("/api/v1/sync/snapshot"))
        .send()
        .await
        .expect("unpaired read");
    assert_eq!(refused.status().as_u16(), 401);

    // 2. P2 acceptance: a paired device can pull an empty snapshot.
    let empty: Value = client
        .get(lb.url("/api/v1/sync/snapshot"))
        .send()
        .await
        .expect("paired read")
        .json()
        .await
        .expect("json");
    assert_eq!(empty["success"], true);
    assert!(empty["envelope"].is_null());

    // 3. The app publishes its own snapshot; the ETag lets a peer skip a
    //    second transfer when nothing changed.
    let published: Value = client
        .post(lb.url("/api/v1/sync/local"))
        .json(&envelope(1000, "device-a"))
        .send()
        .await
        .expect("publish")
        .json()
        .await
        .expect("json");
    let etag = published["etag"].as_str().expect("etag").to_string();
    assert!(!etag.is_empty());

    let not_modified = client
        .get(lb.url("/api/v1/sync/snapshot"))
        .header("if-none-match", format!("\"{etag}\""))
        .send()
        .await
        .expect("conditional read");
    assert_eq!(not_modified.status().as_u16(), 304);

    // 4. The bearer form of the capability works too (used by pairing later).
    let served: Value = client
        .get(lb.bare_url("/api/v1/sync/snapshot"))
        .header("authorization", format!("Bearer {}", lb.token))
        .send()
        .await
        .expect("bearer read")
        .json()
        .await
        .expect("json");
    assert_eq!(served["etag"], etag);
    assert_eq!(served["envelope"]["sentAt"], 1000);

    // 5. A peer pushes its snapshot, the app takes it once and merges.
    let pushed = client
        .post(lb.url("/api/v1/sync/snapshot"))
        .json(&envelope(2000, "device-b"))
        .send()
        .await
        .expect("push");
    assert_eq!(pushed.status().as_u16(), 204);

    let inbox: Value = client
        .get(lb.url("/api/v1/sync/inbox"))
        .send()
        .await
        .expect("take")
        .json()
        .await
        .expect("json");
    assert_eq!(inbox["envelope"]["device"]["id"], "device-b");
    let drained: Value = client
        .get(lb.url("/api/v1/sync/inbox"))
        .send()
        .await
        .expect("take again")
        .json()
        .await
        .expect("json");
    assert!(drained["envelope"].is_null());

    // 6. Wrong methods are refused rather than silently dispatching.
    let wrong = client
        .get(lb.url("/api/v1/sync/local"))
        .send()
        .await
        .expect("wrong method");
    assert_eq!(wrong.status().as_u16(), 405);

    lb.task.abort();
}
