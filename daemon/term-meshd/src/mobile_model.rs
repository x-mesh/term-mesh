//! Model switching for a CLI running in a terminal pane.
//!
//! Both CLIs list their models only inside an interactive `/model` popup, so
//! the popup is driven here by reading the screen after every key. Codex has
//! no inline form at all (`/model x` sends `x` to the model as a prompt);
//! Claude Code's inline `/model <id>` remains for ids the popup does not list.

use std::future::Future;
use std::time::Duration;

use serde::Serialize;

/// The screen text one CLI's popup is recognised by.
///
/// Pinned to Codex v0.160.0 and Claude Code v2.1.288. A release that rewords
/// any of these makes the driver fail closed (Escape, then an error naming the
/// last screen line) instead of pressing keys into a screen it cannot read.
pub struct Tui {
    pub model_title: &'static str,
    /// Codex asks for a reasoning level after the model; Claude applies from
    /// the model list itself.
    pub effort_title: Option<&'static str>,
    pub footer: &'static str,
    pub highlight: char,
    pub current_flag: &'static str,
    pub dropped_flags: &'static [&'static str],
    pub changed: &'static str,
    pub composer: char,
    pub placeholder: &'static str,
    /// Whether a screen line says a turn is running.
    pub busy: fn(&str) -> bool,
}

pub const CODEX: Tui = Tui {
    model_title: "Select Model and Effort",
    effort_title: Some("Select Reasoning Level"),
    footer: "enter ",
    highlight: '›',
    current_flag: "(current)",
    dropped_flags: &["(default)"],
    changed: "Model changed to",
    composer: '›',
    placeholder: "Ask Codex to do anything",
    busy: |line| line.contains(CODEX_BUSY),
};

pub const CLAUDE: Tui = Tui {
    model_title: "Select model",
    effort_title: None,
    footer: "Enter to set as default",
    highlight: '❯',
    current_flag: "✔",
    dropped_flags: &[],
    changed: "Set model to",
    composer: '❯',
    placeholder: "Try \"",
    busy: claude_spinner,
};

pub const SESSION_ONLY: &str = "for this session only";
const CODEX_BUSY: &str = "esc to interrupt";
const BUSY_TAIL_LINES: usize = 10;

/// Claude Code's working line: a rotating glyph, then one capitalised word
/// ending in an ellipsis (`✢ Unfurling… (4s · thinking)`). The finished line
/// reads `✻ Churned for 11s · done` and has no ellipsis after its word.
fn claude_spinner(line: &str) -> bool {
    let mut chars = line.trim_start().chars();
    let Some(glyph) = chars.next() else {
        return false;
    };
    if glyph.is_alphanumeric() || chars.next() != Some(' ') {
        return false;
    }
    let rest: String = chars.collect();
    let Some(end) = rest.find('…') else {
        return false;
    };
    let word = &rest[..end];
    word.chars().next().is_some_and(|c| c.is_ascii_uppercase())
        && word.chars().all(|c| c.is_ascii_alphabetic())
}

/// Whether the CLI is mid-turn, from the bottom of its screen. The session
/// log alone cannot tell: between a finished tool and the next step its last
/// entry looks exactly like an idle session.
pub fn screen_busy(tui: &Tui, screen: &str) -> bool {
    screen
        .lines()
        .rev()
        .filter(|line| !line.trim().is_empty())
        .take(BUSY_TAIL_LINES)
        .any(|line| (tui.busy)(line))
}
const SCROLL_MARKS: &[char] = &['↑', '↓'];
const MESSAGE_MARKS: &[char] = &['•', '⎿'];

const STEP_TIMEOUT: Duration = Duration::from_secs(3);
const POLL_INTERVAL: Duration = Duration::from_millis(80);
const MAX_LIST_STEPS: usize = 64;
const OPEN_POPUP_TRAILING_LINES: usize = 1;
const COMPOSER_TAIL_LINES: usize = 6;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ModelOption {
    pub id: String,
    pub label: String,
    pub description: String,
    pub current: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PopupRow {
    pub index: usize,
    pub label: String,
    pub description: String,
    pub highlighted: bool,
    pub current: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Popup {
    None,
    Models(Vec<PopupRow>),
    Effort(Vec<PopupRow>),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ModelChange {
    pub message: String,
    pub session_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DriveError {
    Busy,
    DraftPresent,
    PopupOpen,
    UnknownModel(String),
    Unrecognized(String),
    PromptGone,
    Io(String),
}

impl DriveError {
    pub fn code(&self) -> &'static str {
        match self {
            DriveError::Busy => "agent_busy",
            DriveError::DraftPresent => "composer_not_empty",
            DriveError::PopupOpen => "popup_open",
            DriveError::UnknownModel(_) => "unknown_model",
            DriveError::Unrecognized(_) => "screen_unrecognized",
            DriveError::PromptGone => "prompt_gone",
            DriveError::Io(_) => "pane_unreachable",
        }
    }

    pub fn message(&self) -> String {
        match self {
            DriveError::Busy => "응답이 끝난 뒤에 모델을 바꿀 수 있습니다.".to_string(),
            DriveError::DraftPresent => {
                "터미널 입력창에 작성 중인 글이 있어 모델을 바꾸지 않았습니다.".to_string()
            }
            DriveError::PopupOpen => "터미널에 다른 메뉴가 열려 있습니다.".to_string(),
            DriveError::UnknownModel(name) => format!("목록에 없는 모델입니다: {name}"),
            DriveError::Unrecognized(line) => {
                format!("터미널 화면을 알아보지 못해 중단했습니다: {line}")
            }
            DriveError::PromptGone => {
                "그 질문은 이미 닫혔습니다. 화면을 새로 고쳐 확인하세요.".to_string()
            }
            DriveError::Io(message) => message.clone(),
        }
    }
}

pub trait PaneDriver {
    fn read_screen(&self) -> impl Future<Output = Result<String, DriveError>> + Send;
    fn send_key(&self, key: &'static str) -> impl Future<Output = Result<(), DriveError>> + Send;
    fn send_text(&self, text: &str) -> impl Future<Output = Result<(), DriveError>> + Send;
    fn send_turn(&self, text: &str) -> impl Future<Output = Result<(), DriveError>> + Send;
    fn pause(&self, duration: Duration) -> impl Future<Output = ()> + Send;
}

pub fn valid_model_id(id: &str) -> bool {
    !id.is_empty()
        && !id.starts_with('-')
        && id.len() <= 64
        && id.chars().all(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':' | '[' | ']')
        })
}

fn parse_row(tui: &Tui, line: &str) -> Option<PopupRow> {
    let mut rest = line.trim_start();
    let mut highlighted = false;
    loop {
        if let Some(after) = rest.strip_prefix(tui.highlight) {
            highlighted = true;
            rest = after.trim_start();
        } else if let Some(after) = rest.strip_prefix(SCROLL_MARKS) {
            rest = after.trim_start();
        } else {
            break;
        }
    }
    let dot = rest.find(". ")?;
    let index: usize = rest[..dot].parse().ok()?;
    let body = rest[dot + 2..].trim();
    let (head, description) = match body.find("  ") {
        Some(split) => (&body[..split], body[split..].trim()),
        None => (body, ""),
    };
    let current = head.contains(tui.current_flag);
    let mut label = head.replace(tui.current_flag, "");
    for flag in tui.dropped_flags {
        label = label.replace(flag, "");
    }
    let label = label.trim().to_string();
    if label.is_empty() {
        return None;
    }
    Some(PopupRow {
        index,
        label,
        description: description.to_string(),
        highlighted,
        current,
    })
}

/// The open popup, read from the last title on screen so popups closed earlier
/// in the scrollback do not count.
pub fn popup(tui: &Tui, screen: &str) -> Popup {
    let lines: Vec<&str> = screen.lines().collect();
    let is_effort = |line: &str| {
        tui.effort_title
            .is_some_and(|title| line.starts_with(title))
    };
    let title = lines.iter().rposition(|line| {
        let line = line.trim();
        line == tui.model_title || is_effort(line)
    });
    let Some(title) = title else {
        return Popup::None;
    };
    let mut rows = Vec::new();
    for (offset, line) in lines[title + 1..].iter().enumerate() {
        if line.trim().starts_with(tui.footer) {
            // An open popup sits at the bottom with at most the status line
            // below it; a footer with more after it is a closed one left in
            // the scrollback.
            let below = lines[title + 2 + offset..]
                .iter()
                .filter(|line| !line.trim().is_empty())
                .count();
            if below > OPEN_POPUP_TRAILING_LINES {
                return Popup::None;
            }
            return if is_effort(lines[title].trim()) {
                Popup::Effort(rows)
            } else {
                Popup::Models(rows)
            };
        }
        if let Some(row) = parse_row(tui, line) {
            rows.push(row);
        }
    }
    Popup::None
}

pub fn highlighted(rows: &[PopupRow]) -> Option<&PopupRow> {
    rows.iter().find(|row| row.highlighted)
}

fn last_changed_line(tui: &Tui, screen: &str) -> Option<(usize, String)> {
    let lines: Vec<&str> = screen.lines().collect();
    let found = lines.iter().rposition(|line| line.contains(tui.changed))?;
    let line = lines[found]
        .trim()
        .trim_start_matches(MESSAGE_MARKS)
        .trim()
        .to_string();
    Some((lines.len() - found, line))
}

fn last_line(screen: &str) -> String {
    screen
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("")
        .to_string()
}

/// Ready means idle, no popup, and an empty composer: `/model` typed into a
/// draft would be appended to text the person is still writing.
pub fn check_ready(tui: &Tui, screen: &str) -> Result<(), DriveError> {
    if popup(tui, screen) != Popup::None {
        return Err(DriveError::PopupOpen);
    }
    let tail: Vec<&str> = screen
        .lines()
        .rev()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .take(COMPOSER_TAIL_LINES)
        .collect();
    if screen_busy(tui, screen) {
        return Err(DriveError::Busy);
    }
    let Some(composer) = tail.iter().find(|line| line.starts_with(tui.composer)) else {
        return Err(DriveError::Unrecognized(last_line(screen)));
    };
    let draft = composer[tui.composer.len_utf8()..].trim();
    if draft.is_empty() || draft.starts_with(tui.placeholder) {
        Ok(())
    } else {
        Err(DriveError::DraftPresent)
    }
}

async fn wait_for<D, T>(
    driver: &D,
    mut accept: impl FnMut(&str) -> Option<T>,
) -> Result<T, DriveError>
where
    D: PaneDriver,
{
    let mut waited = Duration::ZERO;
    loop {
        let screen = driver.read_screen().await?;
        if let Some(value) = accept(&screen) {
            return Ok(value);
        }
        if waited >= STEP_TIMEOUT {
            return Err(DriveError::Unrecognized(last_line(&screen)));
        }
        driver.pause(POLL_INTERVAL).await;
        waited += POLL_INTERVAL;
    }
}

async fn open_model_popup<D: PaneDriver>(
    driver: &D,
    tui: &Tui,
) -> Result<Vec<PopupRow>, DriveError> {
    check_ready(tui, &driver.read_screen().await?)?;
    driver.send_turn("/model").await?;
    wait_for(driver, |screen| match popup(tui, screen) {
        Popup::Models(rows) if highlighted(&rows).is_some() => Some(rows),
        _ => None,
    })
    .await
}

async fn step_down<D: PaneDriver>(
    driver: &D,
    tui: &Tui,
    from: usize,
) -> Result<Vec<PopupRow>, DriveError> {
    driver.send_key("down").await?;
    wait_for(driver, |screen| match popup(tui, screen) {
        Popup::Models(rows) if highlighted(&rows).is_some_and(|row| row.index != from) => {
            Some(rows)
        }
        _ => None,
    })
    .await
}

async fn close_popup<D: PaneDriver>(driver: &D, tui: &Tui) {
    for _ in 0..2 {
        let Ok(screen) = driver.read_screen().await else {
            return;
        };
        if popup(tui, &screen) == Popup::None {
            return;
        }
        let _ = driver.send_key("escape").await;
        driver.pause(POLL_INTERVAL).await;
    }
}

async fn fail_closed<D: PaneDriver, T>(
    driver: &D,
    tui: &Tui,
    result: Result<T, DriveError>,
) -> Result<T, DriveError> {
    if result.is_err() {
        close_popup(driver, tui).await;
    }
    result
}

/// Walks the popup once around (it wraps) so rows scrolled out of its window
/// are listed too, then closes it.
pub async fn list_models<D: PaneDriver>(
    driver: &D,
    tui: &Tui,
) -> Result<Vec<ModelOption>, DriveError> {
    let result = async {
        let mut rows = open_model_popup(driver, tui).await?;
        let start = highlighted(&rows).map(|row| row.index).unwrap_or(0);
        let mut seen: Vec<PopupRow> = Vec::new();
        for _ in 0..MAX_LIST_STEPS {
            for row in &rows {
                if !seen.iter().any(|known| known.index == row.index) {
                    seen.push(row.clone());
                }
            }
            let at = highlighted(&rows).map(|row| row.index).unwrap_or(start);
            rows = step_down(driver, tui, at).await?;
            if highlighted(&rows).map(|row| row.index) == Some(start) {
                break;
            }
        }
        seen.sort_by_key(|row| row.index);
        Ok(seen
            .into_iter()
            .map(|row| ModelOption {
                id: row.label.clone(),
                label: row.label,
                description: row.description,
                current: row.current,
            })
            .collect())
    }
    .await;
    let result = fail_closed(driver, tui, result).await;
    if result.is_ok() {
        close_popup(driver, tui).await;
    }
    result
}

/// Selects `label` and applies it to this session unless `save_default`.
///
/// Codex then asks for a reasoning level; the one it pre-highlights is kept
/// (the session's when the model is unchanged, the model's default otherwise).
/// A Codex model without that step is applied at once and saved as the
/// default; `session_only` in the result reports what the CLI actually did.
pub async fn select_model<D: PaneDriver>(
    driver: &D,
    tui: &Tui,
    label: &str,
    save_default: bool,
) -> Result<ModelChange, DriveError> {
    let before = last_changed_line(tui, &driver.read_screen().await?);
    let apply = |save_default: bool| async move {
        if save_default {
            driver.send_key("enter").await
        } else {
            driver.send_text("s").await
        }
    };
    let result = async {
        let mut rows = open_model_popup(driver, tui).await?;
        let start = highlighted(&rows).map(|row| row.index).unwrap_or(0);
        let mut found = false;
        for step in 0..=MAX_LIST_STEPS {
            let Some(row) = highlighted(&rows).cloned() else {
                return Err(DriveError::Unrecognized(String::new()));
            };
            if row.label == label {
                found = true;
                break;
            }
            if step > 0 && row.index == start {
                break;
            }
            rows = step_down(driver, tui, row.index).await?;
        }
        if !found {
            return Err(DriveError::UnknownModel(label.to_string()));
        }
        if tui.effort_title.is_none() {
            apply(save_default).await?;
        } else {
            driver.send_key("enter").await?;
            let effort = wait_for(driver, |screen| match popup(tui, screen) {
                Popup::Effort(rows) if highlighted(&rows).is_some() => Some(true),
                Popup::None if last_changed_line(tui, screen) != before => Some(false),
                _ => None,
            })
            .await?;
            if effort {
                apply(save_default).await?;
            }
        }
        wait_for(driver, |screen| {
            if popup(tui, screen) != Popup::None {
                return None;
            }
            let latest = last_changed_line(tui, screen);
            (latest != before).then_some(latest).flatten()
        })
        .await
        .map(|(_, message)| ModelChange {
            session_only: message.contains(SESSION_ONLY),
            message,
        })
    }
    .await;
    fail_closed(driver, tui, result).await
}

// ── effort slider (Claude Code) ─────────────────────────────────────────

const EFFORT_TITLE: &str = "Effort";
const EFFORT_FOOTER: &str = "←/→ to adjust";
const EFFORT_MARKER: char = '▲';
const EFFORT_CHANGED: &str = "Set effort level to";

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EffortSlider {
    pub levels: Vec<String>,
    pub current: String,
}

/// The open `/effort` slider: level names on one row, `▲` above the current
/// one. Columns are counted in characters, which matches cells for the
/// single-width box drawing the slider uses.
pub fn effort_slider(screen: &str) -> Option<EffortSlider> {
    let lines: Vec<&str> = screen.lines().collect();
    let footer = lines
        .iter()
        .rposition(|line| line.trim().starts_with(EFFORT_FOOTER))?;
    let below = lines[footer + 1..]
        .iter()
        .filter(|line| !line.trim().is_empty())
        .count();
    if below > OPEN_POPUP_TRAILING_LINES {
        return None;
    }
    let title = lines[..footer]
        .iter()
        .rposition(|line| line.trim() == EFFORT_TITLE)?;
    let window = &lines[title..footer];
    let marker_row = window
        .iter()
        .position(|line| line.contains(EFFORT_MARKER))?;
    let marker = window[marker_row]
        .chars()
        .position(|c| c == EFFORT_MARKER)?;
    let labels = window.get(marker_row + 1)?;
    // Level names are lowercase words; the toggle hint after them ("Tab to
    // toggle") starts with a capital.
    let mut levels: Vec<(String, usize)> = Vec::new();
    let mut word = String::new();
    let mut start = 0;
    for (column, c) in labels.chars().chain(std::iter::once(' ')).enumerate() {
        if !c.is_whitespace() {
            if word.is_empty() {
                start = column;
            }
            word.push(c);
            continue;
        }
        if word.is_empty() {
            continue;
        }
        if !word.chars().all(|c| c.is_ascii_lowercase()) {
            break;
        }
        levels.push((std::mem::take(&mut word), start));
    }
    let current = levels
        .iter()
        .min_by_key(|(name, start)| (start * 2 + name.len()).abs_diff(marker * 2))?
        .0
        .clone();
    Some(EffortSlider {
        levels: levels.into_iter().map(|(name, _)| name).collect(),
        current,
    })
}

fn last_effort_line(screen: &str) -> Option<(usize, String)> {
    let lines: Vec<&str> = screen.lines().collect();
    let found = lines
        .iter()
        .rposition(|line| line.contains(EFFORT_CHANGED))?;
    let line = lines[found]
        .trim()
        .trim_start_matches(MESSAGE_MARKS)
        .trim()
        .to_string();
    Some((lines.len() - found, line))
}

async fn close_slider<D: PaneDriver>(driver: &D) {
    for _ in 0..2 {
        let Ok(screen) = driver.read_screen().await else {
            return;
        };
        if effort_slider(&screen).is_none() {
            return;
        }
        let _ = driver.send_key("escape").await;
        driver.pause(POLL_INTERVAL).await;
    }
}

async fn open_slider<D: PaneDriver>(driver: &D) -> Result<EffortSlider, DriveError> {
    check_ready(&CLAUDE, &driver.read_screen().await?)?;
    driver.send_turn("/effort").await?;
    wait_for(driver, effort_slider).await
}

pub async fn read_effort<D: PaneDriver>(driver: &D) -> Result<EffortSlider, DriveError> {
    let result = open_slider(driver).await;
    close_slider(driver).await;
    result
}

/// Moves the slider to `level` one step at a time, confirming each step on
/// screen, then applies it to this session unless `save_default`.
pub async fn set_effort<D: PaneDriver>(
    driver: &D,
    level: &str,
    save_default: bool,
) -> Result<ModelChange, DriveError> {
    let before = last_effort_line(&driver.read_screen().await?);
    let result = async {
        let mut slider = open_slider(driver).await?;
        let Some(target) = slider.levels.iter().position(|name| name == level) else {
            return Err(DriveError::UnknownModel(level.to_string()));
        };
        for _ in 0..slider.levels.len() * 2 {
            let at = slider
                .levels
                .iter()
                .position(|name| *name == slider.current)
                .ok_or_else(|| DriveError::Unrecognized(slider.current.clone()))?;
            if at == target {
                break;
            }
            driver
                .send_key(if at < target { "right" } else { "left" })
                .await?;
            let from = slider.current.clone();
            slider = wait_for(driver, |screen| {
                effort_slider(screen).filter(|next| next.current != from)
            })
            .await?;
        }
        if slider.current != level {
            return Err(DriveError::Unrecognized(slider.current));
        }
        if save_default {
            driver.send_key("enter").await?;
        } else {
            driver.send_text("s").await?;
        }
        wait_for(driver, |screen| {
            if effort_slider(screen).is_some() {
                return None;
            }
            let latest = last_effort_line(screen);
            (latest != before).then_some(latest).flatten()
        })
        .await
        .map(|(_, message)| ModelChange {
            session_only: message.contains("this session only"),
            message,
        })
    }
    .await;
    if result.is_err() {
        close_slider(driver).await;
    }
    result
}

// ── approval prompts ────────────────────────────────────────────────────

/// How one CLI asks before running a tool: numbered options above a footer,
/// any of which a single digit key picks.
pub struct PromptTui {
    pub footer: &'static str,
    pub highlight: char,
    /// The line above the prompt where its context starts (exclusive).
    pub context_stop: fn(&str) -> bool,
    /// Codex asks first and explains below (its "Reason:" line can end in a
    /// question mark too); Claude explains first and asks last.
    pub question_first: bool,
}

pub const CLAUDE_PROMPT: PromptTui = PromptTui {
    footer: "Esc to cancel",
    highlight: '❯',
    context_stop: |line| line.starts_with('─'),
    question_first: false,
};

pub const CODEX_PROMPT: PromptTui = PromptTui {
    footer: "Press enter to confirm or esc to cancel",
    highlight: '›',
    context_stop: |line| line.starts_with('•') || line.starts_with('›'),
    question_first: true,
};

const PROMPT_CONTEXT_LINES: usize = 8;
const WRAPPED_OPTION_INDENT: &str = "    ";
const MAX_DIGIT_OPTION: usize = 9;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PromptOption {
    pub index: usize,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ApprovalPrompt {
    pub question: String,
    pub context: Vec<String>,
    pub options: Vec<PromptOption>,
    /// Identifies this exact prompt so an answer chosen for one command is
    /// never typed into the next one.
    pub fingerprint: String,
}

fn is_rule(line: &str) -> bool {
    !line.is_empty() && line.chars().all(|c| matches!(c, '─' | '╌' | '▔' | ' '))
}

fn option_row(tui: &PromptTui, line: &str) -> Option<PromptOption> {
    let rest = line.trim_start();
    let rest = rest
        .strip_prefix(tui.highlight)
        .unwrap_or(rest)
        .trim_start();
    let dot = rest.find(". ")?;
    let index: usize = rest[..dot].parse().ok()?;
    let label = rest[dot + 2..].trim();
    (!label.is_empty()).then(|| PromptOption {
        index,
        label: label.to_string(),
    })
}

fn fingerprint(question: &str, context: &[String], options: &[PromptOption]) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    question.hash(&mut hasher);
    context.hash(&mut hasher);
    for option in options {
        option.index.hash(&mut hasher);
        option.label.hash(&mut hasher);
    }
    format!("{:016x}", hasher.finish())
}

/// The approval prompt at the bottom of the screen, if one is waiting.
pub fn approval_prompt(tui: &PromptTui, screen: &str) -> Option<ApprovalPrompt> {
    let lines: Vec<&str> = screen.lines().map(str::trim_end).collect();
    let footer = lines
        .iter()
        .rposition(|line| line.trim().starts_with(tui.footer))?;
    let below = lines[footer + 1..]
        .iter()
        .filter(|line| !line.trim().is_empty())
        .count();
    if below > OPEN_POPUP_TRAILING_LINES {
        return None;
    }
    // Walk up from the footer: option rows, with wrapped option text on
    // indented lines below its row, then the question and its context.
    let mut options: Vec<PromptOption> = Vec::new();
    let mut continuation: Vec<String> = Vec::new();
    let mut at = footer;
    while at > 0 {
        at -= 1;
        let line = lines[at];
        if line.trim().is_empty() {
            continue;
        }
        if let Some(mut option) = option_row(tui, line) {
            for part in continuation.drain(..).rev() {
                option.label.push(' ');
                option.label.push_str(&part);
            }
            options.push(option);
        } else if line.starts_with(WRAPPED_OPTION_INDENT) {
            continuation.push(line.trim().to_string());
        } else {
            break;
        }
    }
    if options.is_empty() || !continuation.is_empty() {
        return None;
    }
    options.reverse();
    let mut context: Vec<String> = Vec::new();
    loop {
        let line = lines[at].trim();
        if (tui.context_stop)(line) || context.len() >= PROMPT_CONTEXT_LINES {
            break;
        }
        if !line.is_empty() && !is_rule(line) {
            context.push(line.to_string());
        }
        if at == 0 {
            break;
        }
        at -= 1;
    }
    context.reverse();
    let asks = |line: &String| line.ends_with('?');
    let asked = if tui.question_first {
        context.iter().position(asks)?
    } else {
        context.iter().rposition(asks)?
    };
    let question = context.remove(asked);
    let fingerprint = fingerprint(&question, &context, &options);
    Some(ApprovalPrompt {
        question,
        context,
        options,
        fingerprint,
    })
}

const PREVIEW_LINES: usize = 4;

/// The last lines a CLI drew above its input box: the spinner and whatever it
/// is streaming, which reaches the session log only once the message ends.
pub fn screen_preview(tui: &PromptTui, screen: &str) -> Vec<String> {
    let lines: Vec<&str> = screen.lines().map(str::trim_end).collect();
    let Some(composer) = lines
        .iter()
        .rposition(|line| line.trim_start().starts_with(tui.highlight))
    else {
        return Vec::new();
    };
    let mut preview: Vec<String> = lines[..composer]
        .iter()
        .rev()
        .map(|line| line.trim())
        .filter(|line| !line.is_empty() && !is_rule(line))
        .take(PREVIEW_LINES)
        .map(str::to_string)
        .collect();
    preview.reverse();
    preview
}

/// Picks `index` on the prompt identified by `fingerprint` with its digit key,
/// then waits for the prompt to close.
pub async fn answer_prompt<D: PaneDriver>(
    driver: &D,
    tui: &PromptTui,
    fingerprint: &str,
    index: usize,
) -> Result<(), DriveError> {
    let screen = driver.read_screen().await?;
    let Some(prompt) = approval_prompt(tui, &screen) else {
        return Err(DriveError::PromptGone);
    };
    if prompt.fingerprint != fingerprint {
        return Err(DriveError::PromptGone);
    }
    if index == 0 || index > MAX_DIGIT_OPTION || !prompt.options.iter().any(|o| o.index == index) {
        return Err(DriveError::PromptGone);
    }
    driver.send_text(&index.to_string()).await?;
    wait_for(driver, |screen| {
        let still = approval_prompt(tui, screen).is_some_and(|p| p.fingerprint == fingerprint);
        (!still).then_some(())
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    const WINDOW: usize = 8;

    #[derive(Clone, Copy, PartialEq)]
    enum Mode {
        Composer,
        Models,
        Effort,
    }

    struct Fake {
        claude: bool,
        models: Vec<(&'static str, bool)>,
        state: Mutex<FakeState>,
    }

    struct FakeState {
        mode: Mode,
        current: usize,
        cursor: usize,
        top: usize,
        draft: String,
        busy: bool,
        history: Vec<String>,
        keys: Vec<String>,
        frozen: bool,
    }

    impl Fake {
        fn new(models: Vec<(&'static str, bool)>, current: usize) -> Self {
            Fake {
                claude: false,
                models,
                state: Mutex::new(FakeState {
                    mode: Mode::Composer,
                    current,
                    cursor: current,
                    top: 0,
                    draft: String::new(),
                    busy: false,
                    history: vec!["  >_ OpenAI Codex (v0.160.0)".to_string()],
                    keys: Vec::new(),
                    frozen: false,
                }),
            }
        }

        fn kiro() -> Self {
            let names = [
                "GPT-5.6-Sol",
                "GPT-5.6-Terra",
                "GPT-5.6-Luna",
                "Kiro Auto",
                "Claude Sonnet 5",
                "Claude Opus 5.5",
                "Claude Opus 5",
                "Claude Haiku 4.5",
                "DeepSeek 3.2",
                "MiniMax M2.5",
                "GLM 5",
                "Qwen3 Coder Next",
                "Jev Auto",
            ];
            let models = names
                .iter()
                .map(|name| (*name, *name != "Kiro Auto"))
                .collect();
            Fake::new(models, 12)
        }

        fn claude() -> Self {
            let names = [
                "Default (recommended)",
                "Opus 5.5",
                "Fable 5.1",
                "Sonnet 5.5",
                "Haiku 4.5",
                "Sonnet 5",
                "Opus 5",
                "Fable 5",
                "Opus 4.8",
                "Opus 4.7",
                "Opus 4.6",
                "Sonnet 4.6",
            ];
            let mut fake = Fake::new(names.iter().map(|name| (*name, false)).collect(), 1);
            fake.claude = true;
            fake
        }

        fn tui(&self) -> &'static Tui {
            if self.claude {
                &CLAUDE
            } else {
                &CODEX
            }
        }

        fn keys(&self) -> Vec<String> {
            self.state.lock().unwrap().keys.clone()
        }

        fn mode(&self) -> Mode {
            self.state.lock().unwrap().mode
        }

        fn render(&self, s: &FakeState) -> String {
            let mut out = s.history.join("\n");
            out.push('\n');
            match s.mode {
                Mode::Composer => {
                    if s.busy {
                        out.push_str("• Working (3s • esc to interrupt)\n");
                    }
                    let tui = self.tui();
                    if s.draft.is_empty() {
                        out.push_str(&format!("{} {}\n", tui.composer, tui.placeholder));
                    } else {
                        out.push_str(&format!("{} {}\n", tui.composer, s.draft));
                    }
                }
                Mode::Models if self.claude => {
                    out.push_str("   Select model\n   Switch between Claude models.\n");
                    for index in s.top..(s.top + WINDOW).min(self.models.len()) {
                        let mark = if index == s.cursor {
                            "❯ "
                        } else if index == s.top && s.top > 0 {
                            "↑ "
                        } else {
                            "  "
                        };
                        let flag = if index == s.current { " ✔" } else { "" };
                        out.push_str(&format!(
                            "   {mark}{}.  {}{flag}   Best for tasks\n",
                            index + 1,
                            self.models[index].0
                        ));
                    }
                    out.push_str("   ● High effort ←/→ to adjust\n");
                    out.push_str(
                        "   Enter to set as default · s to use this session only · Esc to cancel\n",
                    );
                    return out;
                }
                Mode::Models => {
                    out.push_str(&format!("  {}\n", CODEX.model_title));
                    if s.top > 0 {
                        out.push_str("↑\n");
                    }
                    for index in s.top..(s.top + WINDOW).min(self.models.len()) {
                        let mark = if index == s.cursor { "› " } else { "  " };
                        let flag = if index == s.current {
                            " (current)"
                        } else if index == 0 {
                            " (default)"
                        } else {
                            ""
                        };
                        out.push_str(&format!(
                            "{mark}{}. {}{flag}   Kiro credit: 1x.\n",
                            index + 1,
                            self.models[index].0
                        ));
                    }
                    out.push_str("  enter select · esc back\n");
                }
                Mode::Effort => {
                    out.push_str(&format!(
                        "  {} for {}\n",
                        CODEX.effort_title.unwrap(),
                        self.models[s.cursor].0
                    ));
                    out.push_str("  1. Low               Fast\n› 2. Medium (default)  Balanced\n");
                    out.push_str("  enter default · s session · esc back\n");
                }
            }
            out.push_str("  GPT-5.6-Luna high · /tmp/cx\n");
            out
        }

        fn scroll(&self, s: &mut FakeState) {
            if s.cursor < s.top {
                s.top = s.cursor;
            } else if s.cursor >= s.top + WINDOW {
                s.top = s.cursor + 1 - WINDOW;
            }
        }

        fn commit(&self, s: &mut FakeState, session: bool) {
            s.current = s.cursor;
            if self.claude {
                let how = if session {
                    " for this session only"
                } else {
                    " and saved as your default for new sessions"
                };
                s.history.push(format!(
                    "  ⎿  Set model to {}{how}",
                    self.models[s.cursor].0
                ));
                s.mode = Mode::Composer;
                return;
            }
            let suffix = if session {
                " for this session only"
            } else {
                ""
            };
            let id = self.models[s.cursor]
                .0
                .to_ascii_lowercase()
                .replace(' ', "-");
            s.history
                .push(format!("• {} {id} medium{suffix}", CODEX.changed));
            s.mode = Mode::Composer;
        }
    }

    impl PaneDriver for Fake {
        async fn read_screen(&self) -> Result<String, DriveError> {
            let s = self.state.lock().unwrap();
            Ok(self.render(&s))
        }

        async fn send_key(&self, key: &'static str) -> Result<(), DriveError> {
            let mut s = self.state.lock().unwrap();
            s.keys.push(key.to_string());
            if s.frozen {
                return Ok(());
            }
            match (s.mode, key) {
                (Mode::Models, "down") => {
                    s.cursor = (s.cursor + 1) % self.models.len();
                    self.scroll(&mut s);
                }
                (Mode::Models, "enter") if self.claude => self.commit(&mut s, false),
                (Mode::Models, "enter") => {
                    if self.models[s.cursor].1 {
                        s.mode = Mode::Effort;
                    } else {
                        self.commit(&mut s, false);
                    }
                }
                (Mode::Effort, "enter") => self.commit(&mut s, false),
                (Mode::Effort, "escape") => s.mode = Mode::Models,
                (Mode::Models, "escape") => s.mode = Mode::Composer,
                _ => {}
            }
            Ok(())
        }

        async fn send_text(&self, text: &str) -> Result<(), DriveError> {
            let mut s = self.state.lock().unwrap();
            s.keys.push(format!("text:{text}"));
            if (s.mode == Mode::Effort || (self.claude && s.mode == Mode::Models)) && text == "s" {
                self.commit(&mut s, true);
            }
            Ok(())
        }

        async fn send_turn(&self, text: &str) -> Result<(), DriveError> {
            let mut s = self.state.lock().unwrap();
            s.keys.push(format!("turn:{text}"));
            if text == "/model" && !s.frozen {
                s.mode = Mode::Models;
                s.cursor = s.current;
                s.top = 0;
                self.scroll(&mut s);
            }
            Ok(())
        }

        async fn pause(&self, _duration: Duration) {}
    }

    const CAPTURE: &str = "  Select Model and Effort
↑
  6. Claude Opus 5.5        Preview of the next Claude Opus frontier model Kiro credit: 2x.
  12. Qwen3 Coder Next      Latest Qwen coding model available through Kiro Kiro credit: 0.05x.
› 13. Jev Auto (current)    Jev picks one of the administrator-approved models per session.
  enter select · esc back";

    #[test]
    fn parses_a_real_codex_capture() {
        let Popup::Models(rows) = popup(&CODEX, CAPTURE) else {
            panic!("model popup not recognised");
        };
        assert_eq!(rows.len(), 3);
        let row = highlighted(&rows).unwrap();
        assert_eq!(
            (row.index, row.label.as_str(), row.current),
            (13, "Jev Auto", true)
        );
        assert_eq!(rows[0].label, "Claude Opus 5.5");
        assert!(rows[0].description.starts_with("Preview"));
    }

    #[test]
    fn a_closed_popup_in_scrollback_is_not_open() {
        let screen = format!("{CAPTURE}\n• Model changed to x\n› {}", CODEX.placeholder);
        assert_eq!(popup(&CODEX, &screen), Popup::None);
        assert_eq!(check_ready(&CODEX, &screen), Ok(()));
    }

    #[test]
    fn readiness_refuses_a_draft_a_running_turn_and_an_open_popup() {
        assert_eq!(
            check_ready(&CODEX, "› fix the parser"),
            Err(DriveError::DraftPresent)
        );
        let busy = format!("• Working (1s • esc to interrupt)\n› {}", CODEX.placeholder);
        assert_eq!(check_ready(&CODEX, &busy), Err(DriveError::Busy));
        assert_eq!(check_ready(&CODEX, CAPTURE), Err(DriveError::PopupOpen));
    }

    #[test]
    fn model_ids_reject_text_that_could_become_a_prompt() {
        assert!(valid_model_id("opus"));
        assert!(valid_model_id("claude-opus-5-5[1m]"));
        assert!(!valid_model_id("opus please"));
        assert!(!valid_model_id("opus\n/clear"));
        assert!(!valid_model_id(""));
        assert!(!valid_model_id("--help"));
    }

    #[test]
    fn claude_readiness_accepts_only_an_empty_composer() {
        assert_eq!(check_ready(&CLAUDE, "❯ \n───\n  Opus 5.5 high"), Ok(()));
        assert_eq!(
            check_ready(&CLAUDE, "❯ Try \"write a test for <filepath>\""),
            Ok(())
        );
        assert_eq!(
            check_ready(&CLAUDE, "❯ /model opus\n  ⎿ Set model\n❯ fix the"),
            Err(DriveError::DraftPresent)
        );
        assert_eq!(
            check_ready(&CLAUDE, "plain shell $"),
            Err(DriveError::Unrecognized("plain shell $".to_string()))
        );
    }

    #[tokio::test]
    async fn listing_walks_past_the_window_and_closes_the_popup() {
        let fake = Fake::kiro();
        let models = list_models(&fake, &CODEX).await.unwrap();
        assert_eq!(models.len(), 13);
        assert_eq!(models[0].label, "GPT-5.6-Sol");
        assert!(models[12].current);
        assert!(fake.mode() == Mode::Composer);
    }

    #[tokio::test]
    async fn selecting_wraps_and_applies_to_the_session_only() {
        let fake = Fake::kiro();
        let change = select_model(&fake, &CODEX, "GPT-5.6-Luna", false)
            .await
            .unwrap();
        assert!(change.session_only);
        assert!(change.message.contains("gpt-5.6-luna"));
        assert_eq!(fake.keys().iter().filter(|k| *k == "down").count(), 3);
        assert!(fake.keys().contains(&"text:s".to_string()));
        assert!(fake.mode() == Mode::Composer);
    }

    #[tokio::test]
    async fn a_model_without_an_effort_step_reports_the_saved_default() {
        let fake = Fake::kiro();
        let change = select_model(&fake, &CODEX, "Kiro Auto", false)
            .await
            .unwrap();
        assert!(!change.session_only);
        assert!(change.message.contains("kiro-auto"));
        assert!(!fake.keys().contains(&"text:s".to_string()));
    }

    #[tokio::test]
    async fn an_unknown_model_stops_after_one_lap_and_closes_the_popup() {
        let fake = Fake::kiro();
        let err = select_model(&fake, &CODEX, "Nope", false)
            .await
            .unwrap_err();
        assert_eq!(err, DriveError::UnknownModel("Nope".to_string()));
        assert!(fake.mode() == Mode::Composer);
        assert!(fake.keys().iter().filter(|k| *k == "down").count() <= 13);
    }

    #[tokio::test]
    async fn a_draft_is_never_typed_into() {
        let fake = Fake::kiro();
        fake.state.lock().unwrap().draft = "half a thought".to_string();
        assert_eq!(
            select_model(&fake, &CODEX, "GLM 5", false).await,
            Err(DriveError::DraftPresent)
        );
        assert!(fake.keys().is_empty());
    }

    #[tokio::test]
    async fn a_screen_that_never_shows_the_popup_fails_closed() {
        let fake = Fake::kiro();
        fake.state.lock().unwrap().frozen = true;
        let err = select_model(&fake, &CODEX, "GLM 5", false)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "screen_unrecognized");
    }

    const CLAUDE_CAPTURE: &str = "   Select model
   Switch between Claude models. Your pick becomes the default for new sessions.
     1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks
   ❯ 2.  Opus 5.5 ✔             For complex work and everyday tasks
   ↓ 10. Opus 4.7               Best for everyday, complex tasks
      … +2 models
   ● High effort ←/→ to adjust
   Enter to set as default · s to use this session only · Esc to cancel";

    #[test]
    fn parses_a_real_claude_capture() {
        let Popup::Models(rows) = popup(&CLAUDE, CLAUDE_CAPTURE) else {
            panic!("claude model popup not recognised");
        };
        let labels: Vec<_> = rows
            .iter()
            .map(|row| (row.index, row.label.as_str()))
            .collect();
        assert_eq!(
            labels,
            vec![
                (1, "Default (recommended)"),
                (2, "Opus 5.5"),
                (10, "Opus 4.7")
            ]
        );
        let row = highlighted(&rows).unwrap();
        assert_eq!((row.index, row.current), (2, true));
        assert!(!rows[2].current, "the scroll arrow is not a flag");
    }

    #[test]
    fn a_claude_history_line_is_not_a_popup_row() {
        let screen =
            "❯ /model\n  ⎿  Set model to Opus 5.5 for this session only\n❯ \n  Opus 5.5 high";
        assert_eq!(popup(&CLAUDE, screen), Popup::None);
        assert_eq!(check_ready(&CLAUDE, screen), Ok(()));
    }

    #[tokio::test]
    async fn claude_lists_every_model_including_the_scrolled_ones() {
        let fake = Fake::claude();
        let models = list_models(&fake, &CLAUDE).await.unwrap();
        assert_eq!(models.len(), 12);
        assert_eq!(models[11].label, "Sonnet 4.6");
        assert!(models[1].current);
        assert!(fake.mode() == Mode::Composer);
    }

    #[tokio::test]
    async fn claude_applies_to_the_session_from_the_model_list() {
        let fake = Fake::claude();
        let change = select_model(&fake, &CLAUDE, "Sonnet 4.6", false)
            .await
            .unwrap();
        assert!(change.session_only);
        assert_eq!(
            change.message,
            "Set model to Sonnet 4.6 for this session only"
        );
        assert!(
            !fake.keys().contains(&"enter".to_string()),
            "Enter would save the default"
        );
        assert!(fake.mode() == Mode::Composer);
    }

    #[tokio::test]
    async fn claude_saves_the_default_only_when_asked() {
        let fake = Fake::claude();
        let change = select_model(&fake, &CLAUDE, "Haiku 4.5", true)
            .await
            .unwrap();
        assert!(!change.session_only);
        assert!(!fake.keys().contains(&"text:s".to_string()));
    }
    const CLAUDE_PERMISSION: &str = r#"❯ Use the Bash tool to run exactly: touch b.txt
⏺ b.txt 생성 중.
  Creating empty file b.txt
  ⎿  $ touch b.txt
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Create empty file b.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch b.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to
      /tmp/project
      from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No
 Esc to cancel · Tab to amend"#;

    const CODEX_APPROVAL: &str = r#"    {"id": "1eb1cc98-9c38-4209-9f8b-0b638e11f156", "importance": 3, "status": "in_progress"}
• Running touch c.txt
  Would you like to run the following command?
  Environment: local
  Reason: c.txt를 생성하려면 작업 공간에 쓰기 권한이 필요합니다.
  $ touch c.txt
› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `touch c.txt` (p)
  3. No, and tell Codex what to do differently (esc)
  Press enter to confirm or esc to cancel"#;

    #[test]
    fn parses_a_real_claude_permission_prompt() {
        let prompt = approval_prompt(&CLAUDE_PROMPT, CLAUDE_PERMISSION).expect("prompt");
        assert_eq!(prompt.question, "Do you want to proceed?");
        assert!(prompt.context.iter().any(|line| line == "touch b.txt"));
        assert_eq!(
            prompt.context.first().map(String::as_str),
            Some("Bash command")
        );
        let labels: Vec<_> = prompt
            .options
            .iter()
            .map(|o| (o.index, o.label.as_str()))
            .collect();
        assert_eq!(labels[0], (1, "Yes"));
        assert_eq!(
            labels[1],
            (
                2,
                "Yes, and always allow access to /tmp/project from this project"
            )
        );
        assert_eq!(labels[3], (4, "No"));
    }

    #[test]
    fn parses_a_real_codex_approval_prompt() {
        let prompt = approval_prompt(&CODEX_PROMPT, CODEX_APPROVAL).expect("prompt");
        assert_eq!(
            prompt.question,
            "Would you like to run the following command?"
        );
        assert_eq!(
            prompt.context.last().map(String::as_str),
            Some("$ touch c.txt")
        );
        assert_eq!(prompt.options.len(), 3);
        assert_eq!(prompt.options[0].label, "Yes, proceed (y)");
        let asking_reason = CODEX_APPROVAL.replace("Reason:", "Reason: 실행해도 될까요?\n  Note:");
        let prompt = approval_prompt(&CODEX_PROMPT, &asking_reason).expect("prompt");
        assert_eq!(
            prompt.question,
            "Would you like to run the following command?"
        );
    }

    #[test]
    fn an_answered_prompt_left_in_scrollback_is_not_waiting() {
        let screen = format!("{CODEX_APPROVAL}\n✔ You approved codex to run touch c.txt\n• Ran touch c.txt\n› Ask Codex to do anything");
        assert_eq!(approval_prompt(&CODEX_PROMPT, &screen), None);
        assert_eq!(approval_prompt(&CLAUDE_PROMPT, "❯ \n  Opus 5.5 high"), None);
    }

    struct PromptFake {
        screen: Mutex<String>,
        typed: Mutex<Vec<String>>,
    }

    impl PaneDriver for PromptFake {
        async fn read_screen(&self) -> Result<String, DriveError> {
            Ok(self.screen.lock().unwrap().clone())
        }
        async fn send_key(&self, _key: &'static str) -> Result<(), DriveError> {
            Ok(())
        }
        async fn send_text(&self, text: &str) -> Result<(), DriveError> {
            self.typed.lock().unwrap().push(text.to_string());
            *self.screen.lock().unwrap() = "✔ approved\n› Ask Codex to do anything".to_string();
            Ok(())
        }
        async fn send_turn(&self, _text: &str) -> Result<(), DriveError> {
            Ok(())
        }
        async fn pause(&self, _duration: Duration) {}
    }

    #[tokio::test]
    async fn an_answer_types_one_digit_only_into_the_prompt_it_was_chosen_for() {
        let fake = PromptFake {
            screen: Mutex::new(CODEX_APPROVAL.to_string()),
            typed: Mutex::new(Vec::new()),
        };
        let prompt = approval_prompt(&CODEX_PROMPT, CODEX_APPROVAL).unwrap();
        assert_eq!(
            answer_prompt(&fake, &CODEX_PROMPT, "stale", 1).await,
            Err(DriveError::PromptGone)
        );
        assert_eq!(
            answer_prompt(&fake, &CODEX_PROMPT, &prompt.fingerprint, 7).await,
            Err(DriveError::PromptGone)
        );
        assert!(fake.typed.lock().unwrap().is_empty());
        answer_prompt(&fake, &CODEX_PROMPT, &prompt.fingerprint, 1)
            .await
            .unwrap();
        assert_eq!(*fake.typed.lock().unwrap(), vec!["1".to_string()]);
    }
    const CLAUDE_EFFORT: &str = r#"▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   Effort
                             Faster                             Smarter
                             ────────────────────▲─────────────────────      Ultracode  off
                             low     medium     high     xhigh      max      Tab to toggle
   ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel"#;

    #[test]
    fn reads_the_real_effort_slider() {
        let slider = effort_slider(CLAUDE_EFFORT).expect("slider");
        assert_eq!(slider.levels, vec!["low", "medium", "high", "xhigh", "max"]);
        assert_eq!(slider.current, "high");
        let moved = CLAUDE_EFFORT.replace(
            "────────────────────▲──────────",
            "──────────────────────────────▲",
        );
        assert_eq!(effort_slider(&moved).unwrap().current, "xhigh");
    }

    struct SliderFake {
        at: Mutex<usize>,
        open: Mutex<bool>,
        history: Mutex<Vec<String>>,
        keys: Mutex<Vec<String>>,
    }

    impl SliderFake {
        fn new(at: usize) -> Self {
            SliderFake {
                at: Mutex::new(at),
                open: Mutex::new(false),
                history: Mutex::new(Vec::new()),
                keys: Mutex::new(Vec::new()),
            }
        }
    }

    const LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];
    const LEVEL_COLUMNS: [usize; 5] = [29, 37, 48, 57, 68];

    impl PaneDriver for SliderFake {
        async fn read_screen(&self) -> Result<String, DriveError> {
            let mut out = self.history.lock().unwrap().join("\n");
            if *self.open.lock().unwrap() {
                let at = *self.at.lock().unwrap();
                let marker = LEVEL_COLUMNS[at] + LEVELS[at].len() / 2;
                out.push_str("\n   Effort\n");
                out.push_str(&format!("{}▲\n", " ".repeat(marker)));
                out.push_str("                             low     medium     high     xhigh      max      Tab to toggle\n");
                out.push_str(
                    "   ←/→ to adjust · Enter to confirm · s for this session only · Esc to cancel",
                );
            } else {
                out.push_str("\n❯ \n  Opus 5.5 high");
            }
            Ok(out)
        }
        async fn send_key(&self, key: &'static str) -> Result<(), DriveError> {
            self.keys.lock().unwrap().push(key.to_string());
            let mut at = self.at.lock().unwrap();
            match key {
                "right" if *at < 4 => *at += 1,
                "left" if *at > 0 => *at -= 1,
                "escape" => *self.open.lock().unwrap() = false,
                _ => {}
            }
            Ok(())
        }
        async fn send_text(&self, text: &str) -> Result<(), DriveError> {
            if text == "s" {
                let at = *self.at.lock().unwrap();
                *self.open.lock().unwrap() = false;
                self.history.lock().unwrap().push(format!(
                    "  ⎿  Set effort level to {} (this session only): ok",
                    LEVELS[at]
                ));
            }
            Ok(())
        }
        async fn send_turn(&self, text: &str) -> Result<(), DriveError> {
            if text == "/effort" {
                *self.open.lock().unwrap() = true;
            }
            Ok(())
        }
        async fn pause(&self, _duration: Duration) {}
    }

    #[tokio::test]
    async fn effort_moves_one_confirmed_step_at_a_time_and_applies_to_the_session() {
        let fake = SliderFake::new(2);
        let change = set_effort(&fake, "low", false).await.unwrap();
        assert!(change.session_only);
        assert!(change.message.starts_with("Set effort level to low"));
        assert_eq!(*fake.keys.lock().unwrap(), vec!["left", "left"]);
        assert_eq!(read_effort(&fake).await.unwrap().current, "low");
        assert!(!*fake.open.lock().unwrap(), "reading closes the slider");
    }

    #[tokio::test]
    async fn an_unknown_effort_closes_the_slider_without_moving_it() {
        let fake = SliderFake::new(2);
        assert_eq!(
            set_effort(&fake, "turbo", false).await,
            Err(DriveError::UnknownModel("turbo".to_string()))
        );
        assert_eq!(*fake.keys.lock().unwrap(), vec!["escape"]);
    }

    #[test]
    fn the_preview_is_what_streams_above_the_input_box() {
        let claude = "⏺ Reading files\n  ⎿  src/main.rs\n\n✻ Thinking… (esc to interrupt)\n────────\n❯ \n────────\n  Opus 5.5 high";
        assert_eq!(
            screen_preview(&CLAUDE_PROMPT, claude),
            vec![
                "⏺ Reading files",
                "⎿  src/main.rs",
                "✻ Thinking… (esc to interrupt)"
            ]
        );
        let codex = "• Explored\n  └ Read app.js\n• Working (4s • esc to interrupt)\n› Ask Codex to do anything\n  Jev Auto medium";
        assert_eq!(
            screen_preview(&CODEX_PROMPT, codex).last().unwrap(),
            "• Working (4s • esc to interrupt)"
        );
        assert!(screen_preview(&CODEX_PROMPT, "no composer here").is_empty());
    }

    #[test]
    fn claude_is_busy_only_while_its_spinner_runs() {
        for working in [
            "✻ Onioning…",
            "✢ Unfurling… (2s · thinking with high effort)",
            "· Unfurling… (6s · ↓ 251 tokens)",
        ] {
            assert!(
                screen_busy(
                    &CLAUDE,
                    &format!("⏺ 확인 중.\n{working}\n───\n❯ \n───\n  Opus 5.5 high")
                ),
                "{working}"
            );
        }
        for idle in [
            "✻ Churned for 11s · done 오후 11:36",
            "⏺ Listing files in current directory",
            "❯ Try \"fix…\"",
        ] {
            assert!(
                !screen_busy(&CLAUDE, &format!("{idle}\n───\n❯ \n───\n  Opus 5.5 high")),
                "{idle}"
            );
        }
        assert_eq!(
            check_ready(&CLAUDE, "✢ Unfurling… (2s)\n───\n❯ \n  Opus 5.5 high"),
            Err(DriveError::Busy)
        );
    }
}
