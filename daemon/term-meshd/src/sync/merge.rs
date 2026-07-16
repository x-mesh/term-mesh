use std::collections::{BTreeMap, BTreeSet};

use unicode_casefold::UnicodeCaseFold;
use unicode_normalization::UnicodeNormalization;

use super::conflict::{validate_path, MAX_CONFLICT_TOTAL_BYTES};
use super::{
    ConflictContent, ConflictError, ConflictKind, ConflictPathOrigin, ConflictRecord, ConflictSide,
    ObjectDomain, ObjectType,
};

pub const MAX_PATH_CHANGE_COUNT: usize = 100_000;
pub const MAX_PATH_CHANGE_TOTAL_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreeWayFile {
    domain: ObjectDomain,
    path: String,
    base: Option<ConflictContent>,
    local: Option<ConflictContent>,
    remote: Option<ConflictContent>,
}

impl ThreeWayFile {
    pub fn new(
        domain: ObjectDomain,
        path: String,
        base: Option<ConflictContent>,
        local: Option<ConflictContent>,
        remote: Option<ConflictContent>,
    ) -> Result<Self, ConflictError> {
        validate_file_domain(domain)?;
        validate_path(&path)?;
        validate_content_budget(domain, &base, &local, &remote)?;
        Ok(Self {
            domain,
            path,
            base,
            local,
            remote,
        })
    }

    pub fn domain(&self) -> ObjectDomain {
        self.domain
    }

    pub fn path(&self) -> &str {
        &self.path
    }

    pub fn base(&self) -> Option<&ConflictContent> {
        self.base.as_ref()
    }

    pub fn local(&self) -> Option<&ConflictContent> {
        self.local.as_ref()
    }

    pub fn remote(&self) -> Option<&ConflictContent> {
        self.remote.as_ref()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MergeOutcome {
    Resolved(Option<ConflictContent>),
    Conflict(ConflictRecord),
}

pub fn merge_file(input: ThreeWayFile) -> Result<MergeOutcome, ConflictError> {
    validate_path(&input.path)?;
    validate_content_budget(input.domain, &input.base, &input.local, &input.remote)?;
    if input.local == input.remote {
        return Ok(MergeOutcome::Resolved(input.local));
    }
    if input.local == input.base {
        return Ok(MergeOutcome::Resolved(input.remote));
    }
    if input.remote == input.base {
        return Ok(MergeOutcome::Resolved(input.local));
    }

    let kind = match (&input.base, &input.local, &input.remote) {
        (Some(_), None, Some(_)) => ConflictKind::DeleteModify {
            deleted: ConflictSide::Local,
        },
        (Some(_), Some(_), None) => ConflictKind::DeleteModify {
            deleted: ConflictSide::Remote,
        },
        (None, Some(local), Some(remote)) => {
            if local.is_binary() || remote.is_binary() {
                ConflictKind::AddAddBinary
            } else {
                ConflictKind::AddAddText
            }
        }
        (Some(base), Some(local), Some(remote)) if executable_conflict(base, local, remote) => {
            ConflictKind::ExecutableBit
        }
        (_, local, remote) if is_binary(local) || is_binary(remote) => ConflictKind::Binary,
        _ => ConflictKind::Text,
    };
    Ok(MergeOutcome::Conflict(ConflictRecord::new(
        input.domain,
        kind,
        vec![input.path],
        input.base,
        input.local,
        input.remote,
    )?))
}

fn validate_content_budget(
    expected_domain: ObjectDomain,
    base: &Option<ConflictContent>,
    local: &Option<ConflictContent>,
    remote: &Option<ConflictContent>,
) -> Result<(), ConflictError> {
    let mut total = 0usize;
    for content in [base, local, remote].into_iter().flatten() {
        content.validate()?;
        if content.domain() != expected_domain {
            return Err(ConflictError::InvalidObjectDomain);
        }
        total = total
            .checked_add(content.bytes().len())
            .ok_or(ConflictError::BudgetExceeded)?;
    }
    if total > MAX_CONFLICT_TOTAL_BYTES {
        return Err(ConflictError::BudgetExceeded);
    }
    Ok(())
}

fn executable_conflict(
    base: &ConflictContent,
    local: &ConflictContent,
    remote: &ConflictContent,
) -> bool {
    local.executable() != remote.executable()
        && (local.executable() != base.executable() || remote.executable() != base.executable())
}

fn is_binary(content: &Option<ConflictContent>) -> bool {
    content.as_ref().is_some_and(ConflictContent::is_binary)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PathChange {
    base_path: String,
    local_path: Option<String>,
    remote_path: Option<String>,
}

impl PathChange {
    pub fn new(
        base_path: String,
        local_path: Option<String>,
        remote_path: Option<String>,
    ) -> Result<Self, ConflictError> {
        validate_path(&base_path)?;
        if let Some(path) = &local_path {
            validate_path(path)?;
        }
        if let Some(path) = &remote_path {
            validate_path(path)?;
        }
        Ok(Self {
            base_path,
            local_path,
            remote_path,
        })
    }

    pub fn base_path(&self) -> &str {
        &self.base_path
    }

    pub fn local_path(&self) -> Option<&str> {
        self.local_path.as_deref()
    }

    pub fn remote_path(&self) -> Option<&str> {
        self.remote_path.as_deref()
    }
}

pub fn detect_path_conflicts(
    domain: ObjectDomain,
    changes: &[PathChange],
) -> Result<Vec<ConflictRecord>, ConflictError> {
    validate_file_domain(domain)?;
    preflight_changes(changes)?;
    let mut conflicts = Vec::new();
    let target_capacity = changes
        .len()
        .checked_mul(2)
        .ok_or(ConflictError::BudgetExceeded)?;
    let mut targets = Vec::with_capacity(target_capacity);
    let mut edges: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for change in changes {
        for (side, target) in [
            (ConflictSide::Local, &change.local_path),
            (ConflictSide::Remote, &change.remote_path),
        ] {
            if let Some(target) = target {
                targets.push(TargetOccurrence {
                    target: target.clone(),
                    source: change.base_path.clone(),
                    side,
                });
                if target != &change.base_path {
                    edges
                        .entry(change.base_path.clone())
                        .or_default()
                        .insert(target.clone());
                }
            }
        }
    }

    let cycle_paths = rename_cycle_paths(&edges);
    if !cycle_paths.is_empty() {
        conflicts.push(ConflictRecord::new(
            domain,
            ConflictKind::RenameCycle,
            cycle_paths,
            None,
            None,
            None,
        )?);
    }
    append_canonical_collisions(domain, &targets, &mut conflicts)?;
    Ok(conflicts)
}

fn preflight_changes(changes: &[PathChange]) -> Result<(), ConflictError> {
    if changes.len() > MAX_PATH_CHANGE_COUNT {
        return Err(ConflictError::BudgetExceeded);
    }
    let mut total = 0usize;
    for change in changes {
        for path in [
            Some(change.base_path.as_str()),
            change.local_path.as_deref(),
            change.remote_path.as_deref(),
        ]
        .into_iter()
        .flatten()
        {
            validate_path(path)?;
            total = total
                .checked_add(path.len())
                .ok_or(ConflictError::BudgetExceeded)?;
        }
    }
    if total > MAX_PATH_CHANGE_TOTAL_BYTES {
        return Err(ConflictError::BudgetExceeded);
    }
    Ok(())
}

fn canonical_path_key(path: &str) -> String {
    let normalized: String = path.nfc().collect();
    let folded: String = normalized.case_fold().collect();
    folded.nfc().collect()
}

#[derive(Debug)]
struct TargetOccurrence {
    target: String,
    source: String,
    side: ConflictSide,
}

fn append_canonical_collisions(
    domain: ObjectDomain,
    occurrences: &[TargetOccurrence],
    conflicts: &mut Vec<ConflictRecord>,
) -> Result<(), ConflictError> {
    let mut groups: BTreeMap<String, Vec<&TargetOccurrence>> = BTreeMap::new();
    for occurrence in occurrences {
        groups
            .entry(canonical_path_key(&occurrence.target))
            .or_default()
            .push(occurrence);
    }
    for group in groups.into_values() {
        let targets: BTreeSet<&str> = group.iter().map(|item| item.target.as_str()).collect();
        let sources: BTreeSet<&str> = group.iter().map(|item| item.source.as_str()).collect();
        if targets.len() < 2 && sources.len() < 2 {
            continue;
        }
        let all_nfc = targets.iter().all(|path| path.nfc().eq(path.chars()));
        let normalized: BTreeSet<String> =
            targets.iter().map(|path| path.nfc().collect()).collect();
        let kind = if targets.len() == 1 {
            ConflictKind::ExactPathCollision
        } else if normalized.len() == 1 {
            ConflictKind::UnicodeNormalization
        } else if all_nfc {
            ConflictKind::CaseCollision
        } else {
            ConflictKind::UnicodeCaseCollision
        };
        let origins = group
            .into_iter()
            .map(|item| {
                ConflictPathOrigin::new(item.source.clone(), item.target.clone(), item.side)
            })
            .collect();
        conflicts.push(ConflictRecord::new_path_conflict(domain, kind, origins)?);
    }
    Ok(())
}

fn rename_cycle_paths(edges: &BTreeMap<String, BTreeSet<String>>) -> Vec<String> {
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum State {
        Active,
        Visited,
    }
    enum Event {
        Enter(String),
        Exit(String),
    }

    let mut states = BTreeMap::new();
    let mut path = Vec::new();
    let mut positions = BTreeMap::new();
    let mut cycles = BTreeSet::new();
    for node in edges.keys() {
        if states.contains_key(node) {
            continue;
        }
        let mut events = vec![Event::Enter(node.clone())];
        while let Some(event) = events.pop() {
            match event {
                Event::Enter(node) => match states.get(&node) {
                    Some(State::Visited) => {}
                    Some(State::Active) => {
                        if let Some(start) = positions.get(&node).copied() {
                            cycles.extend(path[start..].iter().cloned());
                        }
                    }
                    None => {
                        states.insert(node.clone(), State::Active);
                        positions.insert(node.clone(), path.len());
                        path.push(node.clone());
                        events.push(Event::Exit(node.clone()));
                        if let Some(targets) = edges.get(&node) {
                            for target in targets.iter().rev() {
                                events.push(Event::Enter(target.clone()));
                            }
                        }
                    }
                },
                Event::Exit(node) => {
                    if states.get(&node) == Some(&State::Active) {
                        states.insert(node.clone(), State::Visited);
                        positions.remove(&node);
                        let popped = path.pop();
                        debug_assert_eq!(popped.as_deref(), Some(node.as_str()));
                    }
                }
            }
        }
    }
    cycles.into_iter().collect()
}

fn validate_file_domain(domain: ObjectDomain) -> Result<(), ConflictError> {
    if domain.object_type != ObjectType::FILE {
        return Err(ConflictError::InvalidObjectDomain);
    }
    Ok(())
}
