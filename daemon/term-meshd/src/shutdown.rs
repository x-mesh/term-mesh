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
pub fn install(budget: Duration, stall_threshold: Duration) {
    let base = *BASE.get_or_init(Instant::now);
    HEARTBEAT.store(base.elapsed().as_millis() as u64, Ordering::Relaxed);

    observe_stop_signals();
    spawn_heartbeat();
    spawn_watchdog(budget, stall_threshold);
}

/// Register a second handler for the stop signals, alongside the runtime's.
///
/// `tokio::signal` registers through `signal_hook_registry`, which chains
/// handlers rather than replacing them, so this observer runs without
/// disturbing the runtime's own listener. The handler only stores into
/// atomics, which is async-signal-safe.
fn observe_stop_signals() {
    for signal in [libc::SIGTERM, libc::SIGINT] {
        // SAFETY: the callback touches nothing but atomics, so it is safe to
        // run from a signal handler.
        let registered = unsafe {
            signal_hook_registry::register(signal, || {
                SIGNALLED.store(true, Ordering::SeqCst);
            })
        };
        if let Err(error) = registered {
            tracing::warn!("shutdown watchdog could not observe signal {signal}: {error}");
        }
    }
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
                std::process::exit(0);
            }
        })
        .expect("failed to spawn the shutdown watchdog thread");
}

/// Mark teardown as started. Safe to call after the watchdog already noticed
/// the signal; the earlier timestamp wins.
pub fn begin() {
    let _ = SHUTDOWN_AT.compare_exchange(
        0,
        now_ms().max(1),
        Ordering::SeqCst,
        Ordering::SeqCst,
    );
}

/// Mark teardown as finished so the watchdog stops applying the budget.
pub fn finish() {
    STEP.store(STEP_DONE, Ordering::SeqCst);
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
}
