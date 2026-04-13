# syntax=docker/dockerfile:1.7

# ── Stage 1: Build ────────────────────────────────────────────
FROM rust:1.93-slim@sha256:9663b80a1621253d30b146454f903de48f0af925c967be48c84745537cd35d8b AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
        pkg-config \
        libssl-dev \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 1. Copy ALL workspace member manifests
COPY Cargo.toml Cargo.lock ./
COPY crates/robot-kit/Cargo.toml crates/robot-kit/Cargo.toml
COPY crates/aardvark-sys/Cargo.toml crates/aardvark-sys/Cargo.toml
COPY crates/zeroclaw-macros/Cargo.toml crates/zeroclaw-macros/Cargo.toml
COPY apps/tauri/Cargo.toml apps/tauri/Cargo.toml

# 2. Create dummy source files for all members
RUN mkdir -p src benches \
    crates/robot-kit/src \
    crates/aardvark-sys/src \
    crates/zeroclaw-macros/src \
    apps/tauri/src \
    && echo "fn main() {}" > src/main.rs \
    && echo "fn main() {}" > benches/agent_benchmarks.rs \
    && echo "pub fn placeholder() {}" > crates/robot-kit/src/lib.rs \
    && echo "pub fn placeholder() {}" > crates/aardvark-sys/src/lib.rs \
    && echo "pub fn placeholder() {}" > crates/zeroclaw-macros/src/lib.rs \
    && echo "fn main() {}" > apps/tauri/src/main.rs \
    && echo "fn main() {}" > apps/tauri/build.rs \
    && echo "pub fn placeholder() {}" > apps/tauri/src/lib.rs

# 3. Pre-build dependencies (cache trick)
RUN cargo build --release --locked --bin zeroclaw || true

# 4. Clean up dummy sources and copy REAL sources
RUN rm -rf src benches \
    crates/robot-kit/src \
    crates/aardvark-sys/src \
    crates/zeroclaw-macros/src \
    apps/tauri/src \
    apps/tauri/build.rs
COPY src/ src/
COPY benches/ benches/
COPY crates/ crates/
COPY apps/ apps/
COPY firmware/ firmware/
COPY web/ web/

# 5. Ensure web/dist exists
RUN mkdir -p web/dist && \
    if [ ! -f web/dist/index.html ]; then \
      printf '%s\n' \
        '<!doctype html>' \
        '<html lang="en">' \
        '  <head><meta charset="utf-8"><title>ZeroClaw</title></head>' \
        '  <body><h1>Dashboard Unavailable</h1></body>' \
        '</html>' > web/dist/index.html; \
    fi

# 6. Build final binary (CHỈ BUILD ZEROCLAW)
RUN cargo build --release --locked --bin zeroclaw \
    && cp target/release/zeroclaw /app/zeroclaw \
    && strip /app/zeroclaw

# 7. Prepare runtime directory structure
RUN mkdir -p /zeroclaw-data/.zeroclaw /zeroclaw-data/workspace && \
    printf '%s\n' \
        'workspace_dir = "/zeroclaw-data/workspace"' \
        'config_path = "/zeroclaw-data/.zeroclaw/config.toml"' \
        'api_key = ""' \
        'default_provider = "openrouter"' \
        'default_model = "anthropic/claude-sonnet-4-20250514"' \
        'default_temperature = 0.7' \
        '' \
        '[gateway]' \
        'port = 42617' \
        'host = "[::]"' \
        'allow_public_bind = true' \
        > /zeroclaw-data/.zeroclaw/config.toml && \
    chown -R 65534:65534 /zeroclaw-data

# ── Stage 2: Production Runtime (Distroless) ─────────────────
FROM gcr.io/distroless/cc-debian13:nonroot@sha256:84fcd3c223b144b0cb6edc5ecc75641819842a9679a3a58fd6294bec47532bf7 AS release

COPY --from=builder /app/zeroclaw /usr/local/bin/zeroclaw
COPY --from=builder /zeroclaw-data /zeroclaw-data

ENV ZEROCLAW_WORKSPACE=/zeroclaw-data/workspace
ENV HOME=/zeroclaw-data
ENV ZEROCLAW_GATEWAY_PORT=42617

WORKDIR /zeroclaw-data
USER 65534:65534
EXPOSE 42617
ENTRYPOINT ["zeroclaw"]
CMD ["gateway"]
