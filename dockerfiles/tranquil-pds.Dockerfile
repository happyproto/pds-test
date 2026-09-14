# syntax=docker/dockerfile:1

ARG UPSTREAM_REF
ARG UPSTREAM_SHA
ARG DISTROLESS_IMAGE=gcr.io/distroless/cc-debian13@sha256:e86cf4f565c8eee2cbb2be073bb107dafb14734b53d5872da20fdf47418a02f4

FROM debian:trixie-slim AS src
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG UPSTREAM_REF
ARG UPSTREAM_SHA
RUN set -eu; \
    if [ -z "${UPSTREAM_REF}" ] || [ -z "${UPSTREAM_SHA}" ]; then \
      echo "ERROR: UPSTREAM_REF and UPSTREAM_SHA are both required." >&2; \
      echo "Resolve the commit for the tag with" >&2; \
      echo "'git ls-remote https://tangled.org/tranquil.farm/tranquil-pds refs/tags/<tag>^{}'" >&2; \
      echo "and pass both with --build-arg." >&2; \
      exit 1; \
    fi; \
    git clone --depth 1 --branch "${UPSTREAM_REF}" \
      https://tangled.org/tranquil.farm/tranquil-pds /src; \
    actual="$(git -C /src rev-parse HEAD)"; \
    if [ "$actual" != "${UPSTREAM_SHA}" ]; then \
      echo "ERROR: ${UPSTREAM_REF} points at $actual, not ${UPSTREAM_SHA}." >&2; \
      exit 1; \
    fi; \
    rm -rf /src/.git

RUN set -eu; \
    f=/src/crates/tranquil-oauth/src/client.rs; \
    if ! grep -A3 'cfg(feature = "native-tls-roots")' "$f" \
         | grep -q 'danger_accept_invalid_certs'; then \
      echo "ERROR: in tranquil-oauth ${UPSTREAM_REF}, native-tls-roots no longer" >&2; \
      echo "gates danger_accept_invalid_certs. The PDS would not trust Caddy's" >&2; \
      echo "internal CA, and OAuth in HappyView's e2e tests would fail." >&2; \
      exit 1; \
    fi

FROM node:24-trixie-slim AS frontend
RUN corepack enable && corepack prepare pnpm@11.23.0 --activate
WORKDIR /app
COPY --from=src /src/frontend/ ./
RUN pnpm install --frozen-lockfile && pnpm build

FROM rust:1.96-slim-trixie AS builder
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates pkg-config libssl-dev mold clang protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /stage/var/lib/tranquil-pds/blobs /stage/var/lib/tranquil-pds/store
ENV RUSTFLAGS="-C linker=clang -C link-arg=-fuse-ld=mold"
WORKDIR /app
COPY --from=src /src/ ./
RUN --mount=type=cache,id=tq-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=tq-cargo-git,target=/usr/local/cargo/git \
    --mount=type=cache,id=tq-target,target=/app/target,sharing=locked \
    SQLX_OFFLINE=true cargo build --release -p tranquil-server --features native-tls-roots \
    && cp target/release/tranquil-server /tmp/tranquil-pds

FROM ${DISTROLESS_IMAGE}
COPY --from=builder /tmp/tranquil-pds /usr/local/bin/tranquil-pds
COPY --from=builder --chown=65532:65532 /stage/var/lib/tranquil-pds /var/lib/tranquil-pds
COPY --from=frontend --chown=65532:65532 /app/dist /var/lib/tranquil-pds/frontend
WORKDIR /var/lib/tranquil-pds
ENV SERVER_HOST=[::]
ENV SERVER_PORT=3000
EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/tranquil-pds"]
