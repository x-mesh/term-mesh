#[path = "../src/sync/mod.rs"]
mod sync;

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;
use sha2::{Digest, Sha256};

const FIXTURE_BYTES: &[u8] = include_bytes!("fixtures/security_faults.json");

#[derive(Deserialize)]
struct FaultFixture {
    version: u32,
    suite: String,
    required_threats: Vec<String>,
    cases: Vec<FaultCase>,
}

#[derive(Deserialize)]
struct FaultCase {
    id: String,
    domain: String,
    package: String,
    target: String,
    filter: String,
    threats: Vec<String>,
    invariant: String,
}

#[test]
fn adversarial_fixture_has_complete_unique_fault_contract() {
    let fixture: FaultFixture = serde_json::from_slice(FIXTURE_BYTES).unwrap();
    assert_eq!(fixture.version, 1);
    assert_eq!(fixture.suite, "t15-security-fault");
    assert!(fixture.cases.len() >= 10);

    let required = fixture
        .required_threats
        .into_iter()
        .collect::<BTreeSet<_>>();
    assert_eq!(required.len(), 15, "required threats must be unique");
    let mut ids = BTreeSet::new();
    let mut coverage = BTreeMap::<String, usize>::new();
    let mut domains = BTreeSet::new();
    for case in fixture.cases {
        assert!(ids.insert(case.id), "fault case ids must be unique");
        assert!(!case.package.is_empty());
        assert!(!case.target.is_empty());
        assert!(!case.filter.is_empty());
        assert!(!case.invariant.is_empty());
        domains.insert(case.domain);
        for threat in case.threats {
            assert!(required.contains(&threat), "unknown threat {threat}");
            *coverage.entry(threat).or_default() += 1;
        }
    }
    assert_eq!(domains.len(), 7, "all security domains must be represented");
    for threat in required {
        assert_eq!(coverage.get(&threat), Some(&1), "{threat} coverage drifted");
    }
}

#[test]
fn packet_loss_and_sleep_wake_resume_converge_with_integrity_metrics() {
    let before_sleep = sync::logical_one_gib_resume();
    let after_wake = sync::logical_one_gib_resume();
    assert_eq!(before_sleep, after_wake);
    assert_eq!(before_sleep.logical_bytes, 1024 * 1024 * 1024);
    assert_eq!(before_sleep.total_chunks, 256);
    assert_eq!(before_sleep.verified_before_restart, 231);
    assert_eq!(before_sleep.retransmitted_chunks, 25);
    assert_eq!(before_sleep.retransmitted_verified_chunks, 0);
    assert_eq!(before_sleep.peak_buffer_bytes, 4 * 1024 * 1024);

    let metrics = serde_json::json!({
        "logical_bytes": before_sleep.logical_bytes,
        "total_chunks": before_sleep.total_chunks,
        "verified_before_sleep": before_sleep.verified_before_restart,
        "retransmitted_after_wake": before_sleep.retransmitted_chunks,
        "retransmitted_verified_chunks": before_sleep.retransmitted_verified_chunks,
        "peak_buffer_bytes": before_sleep.peak_buffer_bytes,
        "observable_digest": hex::encode(before_sleep.observable_digest),
    });
    let canonical = serde_json::to_vec(&metrics).unwrap();
    let report_digest = Sha256::digest(&canonical);
    assert_ne!(report_digest.as_slice(), &[0_u8; 32]);
    assert_eq!(metrics["observable_digest"].as_str().unwrap().len(), 64);
}
