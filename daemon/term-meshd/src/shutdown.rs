//! Shutdown instrumentation and the watchdog that bounds teardown.
//!
//! Restarts used to hand the daemon to `systemd`'s `TimeoutStopSec`: the
//! teardown stopped somewhere past `agent sessions terminated` with no log
//! naming the step, and on another host the SIGTERM receipt itself never
//! appeared. Neither shape was diagnosable, because every step was unnamed
//! and unbounded, and every bound that did exist lived on the same runtime
//! that had stopped making progress.
//!
//! So the bound lives on a plain OS thread instead. It learns that a stop
//! was requested from a raw signal handler rather than from the runtime,
//! reports which named step was in flight, and exits on its own once the
//! budget is spent. The relay is then unavailable for the budget rather than
//! for `TimeoutStopSec`, and the journal names the step to fix.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

pub(crate) const FORCED_EXIT_CODE: i32 = 2;

/// Teardown steps, in the order `main` runs them. `STEP_NAMES` is indexed by
/// the values below, so the two must stay in sync.
pub const STEP_IDLE: usize = 0;
pub const STEP_HEADLESS: usize = 1;
pub const STEP_AGENTS: usize = 2;
pub const STEP_RESUME: usize = 3;
pub const STEP_SERVERS: usize = 4;
pub const STEP_DONE: usize = 5;

const STEP_NAMES: [&str; 6] = [
    "idle",
    "headless agent termination",
    "agent session termination",
    "stopped process resume",
    "server join",
    "complete",
];

fn step_name(step: usize) -> &'static str {
    STEP_NAMES.get(step).copied().unwrap_or("unknown")
}

/// Monotonic base for every timestamp this module stores. Storing millis
/// since this instant keeps the shared state lock-free, which is what lets
/// the watchdog thread read it while the runtime is wedged.
static BASE: OnceLock<Instant> = OnceLock::new();

/// Current teardown step, or `STEP_IDLE` before a stop is requested.
static STEP: AtomicUsize = AtomicUsize::new(STEP_IDLE);
/// When the current step started, in millis since `BASE`.
static STEP_AT: AtomicU64 = AtomicU64::new(0);
/// When teardown began, in millis since `BASE`. Zero means it has not begun.
static SHUTDOWN_AT: AtomicU64 = AtomicU64::new(0);
/// Last runtime heartbeat, in millis since `BASE`.
static HEARTBEAT: AtomicU64 = AtomicU64::new(0);
/// Set by the raw SIGTERM/SIGINT handler. The watchdog trusts this even when
/// the runtime never delivers the signal to its own listener.
static SIGNALLED: AtomicBool = AtomicBool::new(false);
static EXITING: AtomicBool = AtomicBool::new(false);

fn now_ms() -> u64 {
    BASE.get()
        .map(|base| base.elapsed().as_millis() as u64)
        .unwrap_or(0)
}

/// Install the raw signal observer, the runtime heartbeat, and the watchdog
/// thread. Call once, from `main`, before the servers start.
///
/// `budget` is how long teardown may take before the watchdog exits the
/// process itself. Keep it below the unit's `TimeoutStopSec` so the daemon,
/// not `systemd`, decides when to stop waiting.
///
/// `stall_threshold` is how far the runtime heartbeat may fall behind before
/// the watchdog reports the runtime as stalled.
pub fn install(budget: Duration, stall_threshold: Duration) -> bool {
    let base = *BASE.get_or_init(Instant::now);
    HEARTBEAT.store(base.elapsed().as_millis() as u64, Ordering::Relaxed);

    let signals_installed = observe_stop_signals();
    spawn_heartbeat();
    spawn_hard_exit(budget);
    spawn_watchdog(budget, stall_threshold);
    signals_installed
}

/// Wait for the raw signal observer rather than registering a second, late
/// Tokio listener. The atomic latch preserves a signal received during daemon
/// initialization until the runtime reaches its shutdown select.
pub async fn stop_requested() {
    while !SIGNALLED.load(Ordering::SeqCst) {
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

/// Register the early stop-signal observer.
///
/// The handler only stores into atomics, which is async-signal-safe. Returns
/// false when either registration fails so main can retain a Tokio fallback.
fn observe_stop_signals() -> bool {
    let mut installed = true;
    for signal in [libc::SIGTERM, libc::SIGINT] {
        // SAFETY: the callback touches nothing but atomics, so it is safe to
        // run from a signal handler.
        let registered = unsafe {
            signal_hook_registry::register(signal, || {
                SIGNALLED.store(true, Ordering::SeqCst);
            })
        };
        if let Err(error) = registered {
            installed = false;
            tracing::warn!("shutdown watchdog could not observe signal {signal}: {error}");
        }
    }
    installed
}

/// Stamp a heartbeat every second so the watchdog can tell a slow teardown
/// apart from a runtime that has stopped polling altogether.
fn spawn_heartbeat() {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            tick.tick().await;
            HEARTBEAT.store(now_ms(), Ordering::Relaxed);
        }
    });
}

fn spawn_watchdog(budget: Duration, stall_threshold: Duration) {
    let budget_ms = budget.as_millis() as u64;
    let stall_ms = stall_threshold.as_millis() as u64;

    std::thread::Builder::new()
        .name("shutdown-watchdog".to_string())
        .spawn(move || {
            let mut stall_reported = false;
            loop {
                std::thread::sleep(Duration::from_millis(200));
                let now = now_ms();

                // A stop was requested but the runtime never reached the
                // teardown path: record the start here so the budget still
                // applies. This is the shape where no shutdown log appeared
                // at all.
                if SIGNALLED.load(Ordering::SeqCst) {
                    let _ = SHUTDOWN_AT.compare_exchange(
                        0,
                        now.max(1),
                        Ordering::SeqCst,
                        Ordering::SeqCst,
                    );
                }

                let lag = now.saturating_sub(HEARTBEAT.load(Ordering::Relaxed));
                if lag >= stall_ms {
                    if !stall_reported {
                        tracing::error!(
                            "runtime stalled: no heartbeat for {}ms while in '{}'",
                            lag,
                            step_name(STEP.load(Ordering::SeqCst))
                        );
                        stall_reported = true;
                    }
                } else {
                    stall_reported = false;
                }

                let started = SHUTDOWN_AT.load(Ordering::SeqCst);
                if started == 0 {
                    continue;
                }
                let elapsed = now.saturating_sub(started);
                if elapsed < budget_ms {
                    continue;
                }

                let step = STEP.load(Ordering::SeqCst);
                if step == STEP_DONE {
                    continue;
                }
                tracing::error!(
                    "shutdown budget of {}ms spent in '{}' ({}ms in that step, runtime heartbeat {}ms behind); exiting now",
                    budget_ms,
                    step_name(step),
                    now.saturating_sub(STEP_AT.load(Ordering::SeqCst)),
                    lag
                );
                // Leaving the rest of teardown undone is the point: the
                // socket is already closed, so every extra second is relay
                // downtime a restart cannot recover.
                // `shutdown-hard-exit` owns termination. This thread only
                // reports diagnostics and is allowed to block in a writer.
            }
        })
        .expect("failed to spawn the shutdown watchdog thread");
}

fn budget_expired(started: u64, now: u64, step: usize, budget_ms: u64) -> bool {
    started != 0 && now.saturating_sub(started) >= budget_ms && step != STEP_DONE
}

/// Enforce the absolute deadline without logging, allocating, or depending on
/// Tokio. The diagnostic watchdog may block in a tracing writer; this separate
/// thread still exits the process at the budget with a failure status.
fn spawn_hard_exit(budget: Duration) {
    std::thread::Builder::new()
        .name("shutdown-hard-exit".to_string())
        .spawn(move || {
            let mut signalled_at: Option<Instant> = None;
            loop {
                std::thread::sleep(Duration::from_millis(25));
                if signalled_at.is_none() && SIGNALLED.load(Ordering::SeqCst) {
                    signalled_at = Some(Instant::now());
                }
                let signal_expired = signalled_at.is_some_and(|at| at.elapsed() >= budget);
                let teardown_expired = budget_expired(
                    SHUTDOWN_AT.load(Ordering::SeqCst),
                    now_ms(),
                    STEP.load(Ordering::SeqCst),
                    budget.as_millis() as u64,
                );
                if (signal_expired || teardown_expired)
                    && STEP.load(Ordering::SeqCst) != STEP_DONE
                    && EXITING
                        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                        .is_ok()
                {
                    std::process::exit(FORCED_EXIT_CODE);
                }
            }
        })
        .expect("failed to spawn the shutdown hard-exit thread");
}

/// Mark teardown as started. Safe to call after the watchdog already noticed
/// the signal; the earlier timestamp wins.
pub fn begin() {
    let _ = SHUTDOWN_AT.compare_exchange(0, now_ms().max(1), Ordering::SeqCst, Ordering::SeqCst);
}

/// Mark teardown as finished so the watchdog stops applying the budget.
fn finish() {
    STEP.store(STEP_DONE, Ordering::SeqCst);
}

/// Exit before the `#[tokio::main]` runtime is dropped. Tokio waits forever
/// for a stuck `spawn_blocking` task during normal drop; an explicit exit is
/// therefore part of the shutdown bound, not merely an optimization.
pub fn exit_success() -> ! {
    while EXITING
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        std::thread::yield_now();
    }
    finish();
    std::process::exit(0)
}

/// Run one teardown step under a bound, logging entry and exit with the time
/// it took. Returns `None` when the step ran out of time.
///
/// A timeout does not cancel work already handed to the blocking pool; it
/// only stops teardown from waiting on it. That is the intended trade: the
/// process is about to exit either way.
pub async fn step<F, T>(index: usize, limit: Duration, work: F) -> Option<T>
where
    F: std::future::Future<Output = T>,
{
    let name = step_name(index);
    STEP.store(index, Ordering::SeqCst);
    STEP_AT.store(now_ms(), Ordering::SeqCst);
    tracing::info!("shutdown step '{name}' started");

    let began = Instant::now();
    match tokio::time::timeout(limit, work).await {
        Ok(value) => {
            tracing::info!(
                "shutdown step '{name}' finished in {}ms",
                began.elapsed().as_millis()
            );
            Some(value)
        }
        Err(_) => {
            tracing::error!(
                "shutdown step '{name}' timed out after {}ms",
                limit.as_millis()
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_step_index_has_a_name() {
        assert_eq!(step_name(STEP_IDLE), "idle");
        assert_eq!(step_name(STEP_HEADLESS), "headless agent termination");
        assert_eq!(step_name(STEP_AGENTS), "agent session termination");
        assert_eq!(step_name(STEP_RESUME), "stopped process resume");
        assert_eq!(step_name(STEP_SERVERS), "server join");
        assert_eq!(step_name(STEP_DONE), "complete");
    }

    #[test]
    fn an_unknown_step_index_still_prints() {
        assert_eq!(step_name(STEP_NAMES.len()), "unknown");
    }

    #[tokio::test]
    async fn a_step_that_finishes_returns_its_value() {
        BASE.get_or_init(Instant::now);
        let value = step(STEP_HEADLESS, Duration::from_secs(5), async { 7 }).await;
        assert_eq!(value, Some(7));
    }

    #[tokio::test]
    async fn a_step_that_overruns_reports_no_value() {
        BASE.get_or_init(Instant::now);
        let value: Option<()> = step(STEP_AGENTS, Duration::from_millis(10), async {
            tokio::time::sleep(Duration::from_secs(30)).await;
        })
        .await;
        assert!(value.is_none());
    }

    #[tokio::test]
    async fn an_early_raw_signal_is_observed_later() {
        SIGNALLED.store(true, Ordering::SeqCst);
        tokio::time::timeout(Duration::from_millis(50), stop_requested())
            .await
            .expect("latched signal was not observed");
        SIGNALLED.store(false, Ordering::SeqCst);
    }

    #[test]
    fn forced_shutdown_is_not_reported_as_success() {
        assert_ne!(FORCED_EXIT_CODE, 0);
    }

    #[test]
    fn hard_deadline_ignores_logging_and_stops_after_completion() {
        assert!(!budget_expired(0, 1_000, STEP_IDLE, 100));
        assert!(!budget_expired(100, 199, STEP_AGENTS, 100));
        assert!(budget_expired(100, 200, STEP_AGENTS, 100));
        assert!(!budget_expired(100, 500, STEP_DONE, 100));
    }
}
