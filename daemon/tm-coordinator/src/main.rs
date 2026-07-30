use anyhow::Result;
use tm_coordinator::{socket, Api, Config};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let config = Config::from_env();
    if !config.enabled {
        eprintln!("tm-coordinator disabled; set TERMMESH_COORDINATOR_ENABLED=1");
        return Ok(());
    }
    let socket_path = config.socket_path.clone();
    let api = Api::open(config)?;
    socket::serve(api, &socket_path).await
}
