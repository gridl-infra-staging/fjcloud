use crate::config::Config;
use crate::state::AppState;

use super::VM_AUTOREPAIR_TASK_NAME;

use axum::Router;
use std::future::Future;
use std::net::SocketAddr;
use tokio::net::TcpListener;

/// Handles returned by background-task startup for shutdown coordination.
pub struct BackgroundHandles {
    pub named_handles: Vec<(&'static str, tokio::task::JoinHandle<()>)>,
    pub access_tracker_handle: tokio::task::JoinHandle<()>,
}

impl BackgroundHandles {
    pub(crate) fn new(
        named_handles: Vec<(&'static str, tokio::task::JoinHandle<()>)>,
        access_tracker_handle: tokio::task::JoinHandle<()>,
    ) -> anyhow::Result<Self> {
        if !named_handles
            .iter()
            .any(|(name, _)| *name == VM_AUTOREPAIR_TASK_NAME)
        {
            anyhow::bail!("VM autorepair background task must always be registered");
        }
        Ok(Self {
            named_handles,
            access_tracker_handle,
        })
    }
}

/// Run both API and S3 servers, then await shutdown and join background tasks.
pub async fn serve(
    state: AppState,
    cfg: &Config,
    shutdown_tx: tokio::sync::watch::Sender<bool>,
    shutdown_rx: tokio::sync::watch::Receiver<bool>,
    handles: BackgroundHandles,
) -> anyhow::Result<()> {
    let s3_app = crate::router::build_s3_router(state.clone(), cfg);
    let app = crate::router::build_router(state);
    let listener = TcpListener::bind(&cfg.listen_addr).await?;
    let s3_listener = TcpListener::bind(&cfg.s3_listen_addr).await?;
    tracing::info!("API listening on {}", cfg.listen_addr);
    tracing::info!("S3 API listening on {}", cfg.s3_listen_addr);

    let s3_shutdown_rx = shutdown_rx.clone();
    let s3_server_handle = tokio::spawn(async move {
        axum::serve(s3_listener, s3_app)
            .with_graceful_shutdown(wait_for_shutdown(s3_shutdown_rx))
            .await
    });

    serve_api_router(listener, app, shutdown_signal(shutdown_tx)).await?;

    match s3_server_handle.await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => tracing::error!("S3 API server failed: {error}"),
        Err(error) => tracing::error!("S3 API server task join failed: {error}"),
    }

    for (name, handle) in handles.named_handles {
        if let Err(error) = handle.await {
            tracing::error!("{name} task failed: {error}");
        }
    }
    handles.access_tracker_handle.abort();
    let _ = handles.access_tracker_handle.await;

    Ok(())
}

/// Serve the main API router with transport peer metadata attached to each request.
///
/// `ApiKeyAuth` uses `ConnectInfo<SocketAddr>` as the only source trusted for
/// `restrict_sources`, so production serving and TCP-bound tests must share
/// this boundary.
pub async fn serve_api_router(
    listener: TcpListener,
    app: Router,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> std::io::Result<()> {
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown)
    .await
}

async fn shutdown_signal(shutdown_tx: tokio::sync::watch::Sender<bool>) {
    tokio::signal::ctrl_c()
        .await
        .expect("failed to install ctrl-c handler");
    tracing::info!("shutdown signal received");
    let _ = shutdown_tx.send(true);
}

async fn wait_for_shutdown(mut shutdown_rx: tokio::sync::watch::Receiver<bool>) {
    let _ = shutdown_rx.wait_for(|&shutdown| shutdown).await;
}
