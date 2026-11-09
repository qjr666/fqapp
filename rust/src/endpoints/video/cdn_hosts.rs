//! The CDN host ladder and the `frma`-driven sample-entry rename.
//!
//! Both exist because of a real iOS failure: the upstream handed a phone a
//! CDN host that resolves nowhere (so no byte ever arrived), and the
//! listening chapters are Opus tracks that were renamed to `mp4a` (so the
//! decoder rejected a perfectly decrypted file). The tests below pin both
//! behaviours so they cannot silently regress.

use super::{
    apply_cenc_index, build_cenc_index, cdn_host_candidates, host_of, u32_be,
};

/// Wraps `payload` in a box of the given type.
fn box_of(typ: &[u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + payload.len());
    out.extend_from_slice(&((8 + payload.len()) as u32).to_be_bytes());
    out.extend_from_slice(typ);
    out.extend_from_slice(payload);
    out
}

/// A minimal MP4 whose only track is an encrypted sample entry.
///
/// `format` is the four-character code `frma` records; `None` builds the
/// same file without a `frma` box.
fn encrypted_audio_fixture(format: Option<&[u8; 4]>) -> Vec<u8> {
    encrypted_audio_fixture_with_body(format, 28)
}

/// The same file, with a different number of bytes between the sample entry's
/// header and its child boxes.
///
/// Encoders disagree about that gap; the rewrite must not depend on it.
fn encrypted_audio_fixture_with_body(format: Option<&[u8; 4]>, body: usize) -> Vec<u8> {
    let mut sinf_payload = Vec::new();
    if let Some(code) = format {
        sinf_payload.extend_from_slice(&box_of(b"frma", code));
    }
    let sinf = box_of(b"sinf", &sinf_payload);
    // An encrypted audio sample entry keeps its audio fields before the
    // child boxes; the index builder looks for `sinf` right after them.
    let mut enca_payload = vec![0u8; body];
    enca_payload.extend_from_slice(&sinf);
    let enca = box_of(b"enca", &enca_payload);

    let mut stsd_payload = vec![0u8; 4]; // version + flags
    stsd_payload.extend_from_slice(&1u32.to_be_bytes()); // entry count
    stsd_payload.extend_from_slice(&enca);
    let stsd = box_of(b"stsd", &stsd_payload);

    let stbl = box_of(b"stbl", &stsd);
    let minf = box_of(b"minf", &stbl);
    let mdia = box_of(b"mdia", &minf);
    let trak = box_of(b"trak", &mdia);
    let moov = box_of(b"moov", &trak);

    let mut out = box_of(b"ftyp", b"isom\x00\x00\x02\x00isomiso2mp41");
    out.extend_from_slice(&moov);
    out
}

/// The offset of the `enca` sample entry inside the fixture.
fn enca_offset(data: &[u8]) -> usize {
    data.windows(4)
        .position(|window| window == b"enca")
        .expect("fixture carries an enca box")
        - 4
}

#[test]
fn encrypted_opus_track_is_renamed_to_opus_not_mp4a() {
    let mut data = encrypted_audio_fixture(Some(b"Opus"));
    let enca_at = enca_offset(&data);
    let index = build_cenc_index(&data, 0, data.len() as u64)
        .expect("index")
        .expect("the fixture carries an encrypted track");
    let key = [7u8; 16];
    apply_cenc_index(&mut data, 0, &index, &key).expect("decrypt");

    assert_eq!(
        &data[enca_at + 4..enca_at + 8],
        b"Opus",
        "the sample entry must carry the codec `frma` records"
    );
    assert!(
        !data.windows(4).any(|window| window == b"enca"),
        "the encrypted sample entry must be gone"
    );
    assert!(
        data.windows(4).any(|window| window == b"free"),
        "the protection scheme box must be blanked into a free box"
    );
}

#[test]
fn encrypted_track_without_frma_falls_back_to_mp4a() {
    let mut data = encrypted_audio_fixture(None);
    let enca_at = enca_offset(&data);
    let index = build_cenc_index(&data, 0, data.len() as u64)
        .expect("index")
        .expect("the fixture carries an encrypted track");
    let key = [7u8; 16];
    apply_cenc_index(&mut data, 0, &index, &key).expect("decrypt");

    assert_eq!(
        &data[enca_at + 4..enca_at + 8],
        b"mp4a",
        "without `frma` the historical guess is the only option left"
    );
}

#[test]
fn the_codec_is_found_even_when_the_entry_layout_differs() {
    // The gap between the sample entry's header and its child boxes is not
    // the same in every file; the rewrite must not depend on it.
    let mut data = encrypted_audio_fixture_with_body(Some(b"Opus"), 32);
    let enca_at = enca_offset(&data);
    let index = build_cenc_index(&data, 0, data.len() as u64)
        .expect("index")
        .expect("the fixture carries an encrypted track");
    let key = [7u8; 16];
    apply_cenc_index(&mut data, 0, &index, &key).expect("decrypt");

    assert_eq!(
        &data[enca_at + 4..enca_at + 8],
        b"Opus",
        "the protection box must still be found and its codec honoured"
    );
}

#[test]
fn the_protection_box_keeps_its_declared_size() {
    let mut data = encrypted_audio_fixture(Some(b"Opus"));
    let sinf_at = data
        .windows(4)
        .position(|window| window == b"sinf")
        .expect("the fixture carries a sinf box")
        - 4;
    let declared = u32_be(&data, sinf_at) as usize;
    let index = build_cenc_index(&data, 0, data.len() as u64)
        .expect("index")
        .expect("the fixture carries an encrypted track");
    let key = [7u8; 16];
    apply_cenc_index(&mut data, 0, &index, &key).expect("decrypt");

    assert_eq!(
        &data[sinf_at + 4..sinf_at + 8],
        b"free",
        "the protection box must be renamed, not resized"
    );
    assert_eq!(
        u32_be(&data, sinf_at) as usize,
        declared,
        "resizing it would leave a zero-length box behind, which ISO BMFF \
         reads as 'until the end of the file'"
    );
    assert!(declared > 8);
}

#[test]
fn the_cdn_ladder_swaps_a_dead_host_for_one_that_serves_the_path() {
    // What the upstream answered for a phone on a Chinese network: a name
    // that does not resolve anywhere.
    let url = "https://v11-novelapp.fqnovel.com/a/b/video.mp4?sign=1";
    let candidates = cdn_host_candidates(url);

    assert_eq!(
        candidates.first().map(String::as_str),
        Some(url),
        "the address the upstream gave must stay first"
    );
    assert!(
        candidates
            .iter()
            .any(|candidate| candidate.starts_with(
                "https://v3-novelapp.fqnovelvod.com/a/b/video.mp4"
            )),
        "the family must be retried on the generation that serves it: {candidates:?}"
    );
    assert!(
        candidates
            .iter()
            .any(|candidate| candidate.starts_with("https://v3-dy-o.zjcdn.com/a/b/video.mp4")),
        "the backup CDN must be in the ladder: {candidates:?}"
    );
    assert!(
        candidates.iter().any(|candidate| candidate.ends_with("?sign=1")),
        "the signature must be kept for the hosts that accept it"
    );
    assert!(
        candidates
            .iter()
            .any(|candidate| candidate.ends_with("/a/b/video.mp4")),
        "a copy without the signature must exist as well"
    );
    assert!(
        !candidates[1..]
            .iter()
            .any(|candidate| candidate.contains("fqnovel.com/a/b")),
        "the dead domain must not be tried again"
    );
}

#[test]
fn the_cdn_ladder_keeps_the_version_the_upstream_asked_for_first() {
    let candidates = cdn_host_candidates("https://v11-novelapp.fqnovel.com/a/b.mp4");
    let version_kept = candidates[1..]
        .iter()
        .find(|candidate| candidate.contains("v11-novelapp"))
        .expect("the upstream's own generation must be retried on a resolvable domain");
    assert!(
        version_kept.starts_with("https://v11-novelapp.fqnovelvod.com/"),
        "only the domain may change: {version_kept}"
    );
}

#[test]
fn the_cdn_ladder_leaves_local_hosts_alone() {
    let url = "http://127.0.0.1:8080/src/a.mp4";
    assert_eq!(
        cdn_host_candidates(url),
        vec![url.to_string()],
        "a local address has no CDN to fall back to"
    );
}

#[test]
fn the_host_of_an_address_keeps_the_credential_out() {
    assert_eq!(
        host_of("https://v3-fq-tts.fqnovelvod.com/a/b.mp4?sign=secret"),
        "v3-fq-tts.fqnovelvod.com"
    );
}
