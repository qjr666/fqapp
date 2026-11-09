//! A second opinion on where a CDN host lives.
//!
//! A CDN name is a CNAME chain (`fqnovelvod.com` -> `volcgslb.com` ->
//! `volcmcdn3.com`), so which node answers for it depends on the resolver
//! that is asked. On the phone the system resolver handed out nodes that
//! refused the connection outright — `Connection refused (os error 61)` for
//! every address of every `*-novelapp` name, while the very same name
//! answers from a node somebody else names. Asking a public
//! DNS-over-HTTPS resolver and pinning the request to the address it
//! returns gets around the dead node set.
//!
//! The resolvers are addressed by IP, so the lookup needs no name
//! resolution of its own: on a network whose resolver cannot even name
//! `dns.alidns.com` the fallback still works.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::Value;

/// The public resolvers to ask, in order.
///
/// The first two are domestic, so they are the ones that answer on a
/// Chinese network; the last two cover a network where those are blocked.
const RESOLVERS: &[&str] = &[
    "https://223.5.5.5/resolve",    // AliDNS
    "https://120.53.53.53/resolve", // DNSPod
    "https://8.8.8.8/resolve",      // Google
    "https://1.1.1.1/dns-query",    // Cloudflare
];

/// How long one resolver may take before the next one is asked.
const RESOLVER_TIMEOUT: Duration = Duration::from_secs(4);

/// How long an answer stays good.
///
/// A CDN moves its nodes around, but not within a chapter. The answer is
/// kept for ten minutes so a chapter with twenty candidate hosts does not
/// ask the same resolver twenty times, and no longer: a node that has
/// gone away must not keep being sent back to.
const ANSWER_TTL: Duration = Duration::from_secs(600);

/// How many addresses one resolver may contribute.
const MAX_ADDRESSES_PER_RESOLVER: usize = 4;

/// How many addresses one name may be pinned to in total.
const MAX_ADDRESSES: usize = 12;

/// The client that talks to the resolvers.
static RESOLVER_CLIENT: OnceLock<Option<reqwest::Client>> = OnceLock::new();

fn resolver_client() -> Option<&'static reqwest::Client> {
    RESOLVER_CLIENT
        .get_or_init(|| {
            reqwest::Client::builder()
                .timeout(RESOLVER_TIMEOUT)
                .build()
                .ok()
        })
        .as_ref()
}

/// The answers already collected, with the moment they were collected.
type AnswerCache = Mutex<HashMap<String, (Instant, Vec<IpAddr>)>>;

static ANSWERS: OnceLock<AnswerCache> = OnceLock::new();

fn answers() -> &'static AnswerCache {
    ANSWERS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Where a CDN host lives, according to a public resolver.
///
/// Returns an empty list when no resolver answered. The addresses are the
/// ones the resolvers named for this exact name; the caller pins the
/// request to them.
///
/// Every resolver is asked, not just the first one that answers: the
/// resolvers are spread over the world, and the nodes a phone's own
/// resolver names are exactly the ones that may be dead. Asking the
/// overseas resolvers as well widens the set the request can be pinned to.
pub async fn resolve_host(host: &str) -> Vec<IpAddr> {
    let host = host.trim().to_ascii_lowercase();
    if host.is_empty() {
        return Vec::new();
    }
    if let Some(hit) = cached(&host) {
        return hit;
    }
    let answers = futures::future::join_all(
        RESOLVERS
            .iter()
            .map(|base| ask(base, &host))
            .collect::<Vec<_>>(),
    )
    .await;
    let mut found: Vec<IpAddr> = Vec::new();
    for answer in answers {
        let Some(addresses) = answer else {
            continue;
        };
        for address in addresses {
            if !found.contains(&address) {
                found.push(address);
            }
        }
    }
    found.truncate(MAX_ADDRESSES);
    if !found.is_empty() {
        log::info!("cdn dns: {} lives at {} address(es)", host, found.len());
        remember(&host, &found);
    }
    found
}

/// Asks one resolver where the name lives.
async fn ask(base: &str, host: &str) -> Option<Vec<IpAddr>> {
    let client = resolver_client()?;
    let url = format!("{base}?name={host}&type=A");
    let response = client
        .get(&url)
        .header(reqwest::header::ACCEPT, "application/dns-json")
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let body = response.text().await.ok()?;
    let parsed: Value = serde_json::from_str(&body).ok()?;
    parse_answer(&parsed)
}

/// Picks the addresses out of a DNS-over-HTTPS answer.
///
/// The answer lists the whole CNAME chain; only the records of type A (1)
/// and AAAA (28) are addresses.
fn parse_answer(body: &Value) -> Option<Vec<IpAddr>> {
    let records = body.get("Answer")?.as_array()?;
    let mut out: Vec<IpAddr> = Vec::new();
    for record in records {
        let Some(kind) = record.get("type").and_then(|value| value.as_i64()) else {
            continue;
        };
        let Some(data) = record.get("data").and_then(|value| value.as_str()) else {
            continue;
        };
        let address = match kind {
            1 => data.parse::<std::net::Ipv4Addr>().ok().map(IpAddr::V4),
            28 => data.parse::<std::net::Ipv6Addr>().ok().map(IpAddr::V6),
            _ => None,
        };
        if let Some(address) = address {
            if !out.contains(&address) {
                out.push(address);
            }
        }
    }
    if out.is_empty() {
        return None;
    }
    // IPv4 first: a v4 node is the one that answered in the field, and a
    // phone whose IPv6 route is half-broken still reaches the v4 node.
    out.sort_by_key(|address| match address {
        IpAddr::V4(_) => 0,
        IpAddr::V6(_) => 1,
    });
    out.truncate(MAX_ADDRESSES_PER_RESOLVER);
    Some(out)
}

/// The answer for this host, when it is still fresh.
fn cached(host: &str) -> Option<Vec<IpAddr>> {
    let map = answers().lock().ok()?;
    let (when, addrs) = map.get(host)?;
    if when.elapsed() > ANSWER_TTL {
        return None;
    }
    Some(addrs.clone())
}

/// Keeps the answer for this host for a while.
fn remember(host: &str, addrs: &[IpAddr]) {
    if let Ok(mut map) = answers().lock() {
        map.insert(host.to_string(), (Instant::now(), addrs.to_vec()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_the_addresses_out_of_a_cname_chain() {
        let body = serde_json::json!({
            "Status": 0,
            "Answer": [
                {"name": "v5-novelapp.fqnovelvod.com.", "TTL": 157, "type": 5,
                 "data": "v5-novelapp.fqnovelvod.com.volcgslb.com."},
                {"name": "v5-novelapp.fqnovelvod.com.volcgslb.com.", "TTL": 14, "type": 5,
                 "data": "v5-novelapp.fqnovelvod.com.847550.volcmcdn3.com."},
                {"name": "v5-novelapp.fqnovelvod.com.847550.volcmcdn3.com.", "TTL": 60, "type": 1,
                 "data": "122.228.29.227"},
                {"name": "v5-novelapp.fqnovelvod.com.847550.volcmcdn3.com.", "TTL": 60, "type": 1,
                 "data": "122.228.29.228"},
                {"name": "v5-novelapp.fqnovelvod.com.847550.volcmcdn3.com.", "TTL": 60, "type": 28,
                 "data": "240e:95d:1904:f4:8000:0:b00:42"}
            ]
        });
        let addrs = parse_answer(&body).expect("the answer carries addresses");
        assert_eq!(addrs.len(), 3);
        assert_eq!(
            addrs[0],
            IpAddr::V4(std::net::Ipv4Addr::new(122, 228, 29, 227))
        );
        assert_eq!(
            addrs[1],
            IpAddr::V4(std::net::Ipv4Addr::new(122, 228, 29, 228))
        );
        assert!(matches!(addrs[2], IpAddr::V6(_)));
    }

    #[test]
    fn an_answer_without_addresses_is_not_an_address() {
        assert!(parse_answer(&serde_json::json!({"Status": 0, "Answer": []})).is_none());
        assert!(parse_answer(&serde_json::json!({"Status": 3})).is_none());
    }
}
