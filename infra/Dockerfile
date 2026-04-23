# ---------------------------------------------------------------------------
# Griddle API — multi-stage Docker build
# ---------------------------------------------------------------------------
# Build:  docker build -t griddle-api ./infra
# Run:    docker run -p 3001:3001 --env-file .env.local griddle-api

FROM rust:1.93-slim-bookworm AS build-base

RUN apt-get update && apt-get install -y pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# `docker-compose.override.yml.example` targets `builder` for cargo-watch hot reload.
FROM build-base AS builder
RUN cargo install cargo-watch --locked

FROM build-base AS release-builder
COPY Cargo.toml Cargo.lock ./
COPY api/ api/
COPY billing/ billing/
COPY metering-agent/ metering-agent/
COPY aggregation-job/ aggregation-job/
COPY pricing-calculator/ pricing-calculator/

RUN cargo build --release -p api

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=release-builder /build/target/release/fjcloud-api /usr/local/bin/fjcloud-api

EXPOSE 3001

ENTRYPOINT ["fjcloud-api"]
