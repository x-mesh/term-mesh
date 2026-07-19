use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;

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
