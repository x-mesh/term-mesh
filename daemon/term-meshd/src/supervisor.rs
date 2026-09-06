use std::future::Future;
use std::time::Duration;

use tokio::task::JoinSet;
use tokio::time::timeout;

/// How long a server waits for its connection tasks before aborting them.
///
/// Half of `main.rs`'s `SERVER_JOIN_LIMIT`, and deliberately not equal to it:
/// the rest of that budget belongs to whatever each server does after the
/// drain. Raising this to meet the outer bound is what made those steps
/// unreachable, so keep the gap.
pub const CONNECTION_DRAIN_LIMIT: Duration = Duration::from_millis(2500);

pub fn spawn_supervised<F>(joinset: &mut JoinSet<()>, future: F)
where
    F: Future<Output = ()> + Send + 'static,
{
    joinset.spawn(future);
}

/// Drain a server's connection tasks, then abort whatever is left.
///
/// `budget` must be strictly smaller than the caller's own bound, with room to
/// spare for the work that follows this call. It used to be a fixed 5s while
/// `main.rs` bounded the whole server-join step at the same 5s, so a drain that
/// ran long left zero budget behind it: the abort below, the peer server's
/// surface reaping and its socket-file removal were all skipped — exactly when
/// there were enough connections for the drain to run long in the first place.
///
/// Measured on a two-day-old production daemon (2026-09-06, jw-server): the
/// drain hit its 5s, the outer step timed out 25µs later, and three peer
/// surfaces went unreaped. Linux hides that behind `KillMode=control-group`;
/// a GUI-launched daemon has no such backstop.
pub async fn shutdown_supervised(joinset: &mut JoinSet<()>, label: &str, budget: Duration) {
    if joinset.is_empty() {
        return;
    }

    match timeout(budget, async {
        while let Some(result) = joinset.join_next().await {
            if let Err(err) = result {
                tracing::warn!("{label}: supervised task ended with join error: {err}");
            }
        }
    })
    .await
    {
        Ok(()) => {}
        Err(_) => {
            tracing::warn!(
                "{label}: supervised task shutdown timed out after {}ms; aborting",
                budget.as_millis()
            );
            joinset.abort_all();
            while joinset.join_next().await.is_some() {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    /// A task that ignores shutdown must not hold the drain past its budget:
    /// everything the caller does after this call is paid for out of the rest
    /// of the caller's own bound.
    #[tokio::test]
    async fn a_task_that_never_finishes_is_aborted_at_the_budget() {
        let mut joinset = JoinSet::new();
        spawn_supervised(&mut joinset, async {
            std::future::pending::<()>().await;
        });

        let began = Instant::now();
        shutdown_supervised(&mut joinset, "test", Duration::from_millis(200)).await;
        let waited = began.elapsed();

        assert!(waited >= Duration::from_millis(200), "returned before its budget: {waited:?}");
        assert!(waited < Duration::from_secs(2), "held past its budget: {waited:?}");
        assert!(joinset.is_empty(), "the drain must leave nothing behind");
    }

    #[tokio::test]
    async fn a_cooperative_task_does_not_spend_the_budget() {
        let mut joinset = JoinSet::new();
        spawn_supervised(&mut joinset, async {});

        let began = Instant::now();
        shutdown_supervised(&mut joinset, "test", Duration::from_secs(5)).await;

        assert!(began.elapsed() < Duration::from_secs(1));
    }
}
