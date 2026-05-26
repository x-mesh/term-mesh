use std::future::Future;
use std::time::Duration;

use tokio::task::JoinSet;
use tokio::time::timeout;

pub fn spawn_supervised<F>(joinset: &mut JoinSet<()>, future: F)
where
    F: Future<Output = ()> + Send + 'static,
{
    joinset.spawn(future);
}

pub async fn shutdown_supervised(joinset: &mut JoinSet<()>, label: &str) {
    if joinset.is_empty() {
        return;
    }

    match timeout(Duration::from_secs(5), async {
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
            tracing::warn!("{label}: supervised task shutdown timed out after 5s; aborting");
            joinset.abort_all();
            while joinset.join_next().await.is_some() {}
        }
    }
}
