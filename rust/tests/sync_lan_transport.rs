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

/// P4 acceptance over the real listener: a device that has not paired cannot
/// read the snapshot, exchanging the host's one-time code grants a secret that
/// unlocks only sync routes, and revoking that device closes the door again
/// without restarting the server.
#[tokio::test]
async fn pairing_grants_a_secret_that_can_be_revoked() {
    let dir = TempDir::new("sync-lan-pairing");
    let server = build_server(&dir, None, &[], &[], &pool_json(2)).await;
    let lb = start_listener(server, ListenMode::Lan).await;
    let client = reqwest::Client::new();

    // 1. Both the reading history and the device list stay private.
    let unpaired = client
        .get(lb.bare_url("/api/v1/sync/snapshot"))
        .send()
        .await
        .expect("unpaired read");
    assert_eq!(unpaired.status().as_u16(), 401);
    let unpaired_hosts = client
        .get(lb.bare_url("/api/v1/sync/hosts"))
        .send()
        .await
        .expect("unpaired device list");
    assert_eq!(unpaired_hosts.status().as_u16(), 401);

    // 2. The host owns the capability, so only it can issue a code.
    let denied_code = client
        .post(lb.bare_url("/api/v1/sync/pair/code"))
        .send()
        .await
        .expect("foreign code request");
    assert_eq!(denied_code.status().as_u16(), 401);
    let issued: Value = client
        .post(lb.url("/api/v1/sync/pair/code"))
        .send()
        .await
        .expect("issue code")
        .json()
        .await
        .expect("json");
    let code = issued["code"].as_str().expect("code").to_string();
    assert_eq!(code.len(), 6);

    // 3. A wrong code is refused. It reaches the handler without a capability
    //    (the code is the credential), but grants nothing.
    let wrong_code = if code == "000000" { "111111" } else { "000000" };
    let wrong = client
        .post(lb.bare_url("/api/v1/sync/pair"))
        .json(&json!({
            "code": wrong_code,
            "device": { "id": "device-b", "name": "peer", "platform": "android" },
        }))
        .send()
        .await
        .expect("wrong code");
    assert_eq!(wrong.status().as_u16(), 400);

    // 4. The right code yields a long-lived secret.
    let paired: Value = client
        .post(lb.bare_url("/api/v1/sync/pair"))
        .json(&json!({
            "code": code,
            "device": { "id": "device-b", "name": "peer", "platform": "android" },
        }))
        .send()
        .await
        .expect("pair")
        .json()
        .await
        .expect("json");
    let secret = paired["secret"].as_str().expect("secret").to_string();
    let bearer = format!("Bearer {secret}");

    let snapshot = client
        .get(lb.bare_url("/api/v1/sync/snapshot"))
        .header("authorization", &bearer)
        .send()
        .await
        .expect("paired read");
    assert_eq!(snapshot.status().as_u16(), 200);

    let hosts: Value = client
        .get(lb.bare_url("/api/v1/sync/hosts"))
        .header("authorization", &bearer)
        .send()
        .await
        .expect("host list")
        .json()
        .await
        .expect("json");
    assert_eq!(hosts["devices"].as_array().unwrap().len(), 1);
    assert_eq!(hosts["devices"][0]["id"], "device-b");
    assert!(hosts["devices"][0].get("secret").is_none());

    // The code is single-use.
    let reused = client
        .post(lb.bare_url("/api/v1/sync/pair"))
        .json(&json!({
            "code": code,
            "device": { "id": "device-c", "name": "other", "platform": "ios" },
        }))
        .send()
        .await
        .expect("reused code");
    assert_eq!(reused.status().as_u16(), 400);

    // 5. Revoking the device invalidates its secret immediately.
    let revoked = client
        .post(lb.url("/api/v1/sync/hosts/revoke"))
        .json(&json!({ "deviceId": "device-b" }))
        .send()
        .await
        .expect("revoke");
    assert_eq!(revoked.status().as_u16(), 200);
    let after = client
        .get(lb.bare_url("/api/v1/sync/snapshot"))
        .header("authorization", &bearer)
        .send()
        .await
        .expect("revoked read");
    assert_eq!(after.status().as_u16(), 401);

    lb.task.abort();
}
