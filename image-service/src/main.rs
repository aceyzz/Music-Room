use axum::{
    extract::{DefaultBodyLimit, Json},
    http::StatusCode,
    routing::{get, post},
    Router,
};
use base64::{engine::general_purpose::STANDARD, Engine};
use image::{DynamicImage, ImageFormat};
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use tracing::info;

/// Largest request body /resize accepts. axum's default (2 MB) is below what
/// the backend sends: it allows 5 MiB images (media.MaxUploadBytes in
/// backend/internal/media/client.go) and base64-encodes them into JSON, so
/// 5 MiB becomes ~6.7 MiB of body. Anything over the limit gets a 413, which
/// the backend can only report as "could not process image".
const MAX_BODY_BYTES: usize = 8 * 1024 * 1024;

#[derive(Deserialize)]
struct ResizeRequest {
    image_base64: String,
    width: u32,
    height: u32,
}

#[derive(Serialize)]
struct ResizeResponse {
    image_base64: String,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt().with_env_filter("info").init();

    let app = Router::new()
        .route("/health", get(health))
        .route("/resize", post(resize))
        .layer(DefaultBodyLimit::max(MAX_BODY_BYTES));

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080")
        .await
        .expect("failed to bind image service");

    info!("image-service listening on :8080");
    axum::serve(listener, app)
        .await
        .expect("image service server failed");
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse { status: "ok" })
}

async fn resize(Json(payload): Json<ResizeRequest>) -> Result<Json<ResizeResponse>, (StatusCode, String)> {
    if payload.width == 0 || payload.height == 0 {
        return Err((StatusCode::BAD_REQUEST, "width and height must be > 0".to_string()));
    }

    let raw = STANDARD
        .decode(payload.image_base64)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("invalid base64 payload: {e}")))?;

    let image = image::load_from_memory(&raw)
        .map_err(|e| (StatusCode::BAD_REQUEST, format!("invalid image bytes: {e}")))?;

    let resized = image.resize_exact(payload.width, payload.height, image::imageops::FilterType::Lanczos3);
    let encoded = encode_png(resized)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, format!("image encoding failed: {e}")))?;

    Ok(Json(ResizeResponse {
        image_base64: STANDARD.encode(encoded),
    }))
}

fn encode_png(image: DynamicImage) -> image::ImageResult<Vec<u8>> {
    let mut buffer = Vec::new();
    let mut cursor = Cursor::new(&mut buffer);
    image.write_to(&mut cursor, ImageFormat::Png)?;
    Ok(buffer)
}
