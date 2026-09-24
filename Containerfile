# mcl-victron
#
# Victron GX telemetry (dbus-flashmq MQTT on the LAN), recorded in the service's
# own reckon-db store on the /data volume and published on the mesh.
#
# ⚠ THE RUNTIME IS PINNED IN FOUR PLACES AND THEY MUST AGREE: this builder (by
# digest), `.github/workflows/lint-and-test.yml', `.tool-versions', and the VM
# the suite runs on. mcl_victron_service_tests compares all four. A floating
# `erlang:28-alpine' shipped OTP 28.5 to the fleet on 2026-09-22.
FROM docker.io/hexpm/erlang:28.4.3-alpine-3.22.6@sha256:3815b99f486c2509baf556045bca0c5fc1c3ee50fb50a80590534f22cb48736c AS builder
WORKDIR /build

# Nothing here builds rocksdb (mcl_om 0.27 dropped barrel_docdb; the store is
# reckon-db on khepri/ra). cmake and perl stay for macula's NIF builds.
RUN apk add --no-cache git curl bash build-base cmake perl linux-headers openssl-dev

# macula's NIFs are Rust. Pinned to the release the CI image carries.
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain 1.98.1 --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
# A cdylib cannot be statically linked against musl.
ENV RUSTFLAGS="-C target-feature=-crt-static"
# macula's QUIC NIF: build it here rather than fetch a glibc prebuilt that
# loads on the build host and fails on alpine.
ENV MACULA_FORCE_SOURCE_BUILD=1

RUN curl -fsSL https://github.com/erlang/rebar3/releases/download/3.27.0/rebar3 \
        -o /usr/local/bin/rebar3 \
    && echo "af85aab41f9fd74bdd6341ebdf6fe9c88077aab9f8eac82371583fa02f2b0bdf  /usr/local/bin/rebar3" \
        | sha256sum -c - \
    && chmod +x /usr/local/bin/rebar3

# Dependencies resolve from rebar.config alone, so this layer survives changes
# to config/ and apps/.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM docker.io/alpine:3.22
# LINKS THE PACKAGE TO THE REPOSITORY, so ghcr shows it there and it inherits
# the repository's visibility.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-victron"
# libstdc++/libgcc for the NIFs, openssl for OTP's crypto, curl for the health
# check. hecate-victron's runtime was libstdc++, ncurses-libs and openssl.
RUN apk add --no-cache ncurses-libs libstdc++ libgcc openssl ca-certificates curl
WORKDIR /app
COPY --from=builder /build/_build/prod/rel/mcl_victron ./

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

ENV MCL_NODE_NAME=mcl_victron
ENV MCL_NODE_HOST=127.0.0.1
ENV MCL_COOKIE=mcl_victron
ENV MCL_HEALTH_PORT=8483
# The reckon-db store. A named volume or a bind mount on a bulk drive; without
# one every recreate forgets every reading.
ENV MCL_DATA_DIR=/data
# The GX's broker on the LAN. The host is deploy config; the rest are Venus
# OS's own defaults.
ENV VICTRON_MQTT_PORT=1883
ENV VICTRON_MQTT_KEEPALIVE_SEC=30

VOLUME ["/etc/mcl/secrets", "/data"]

EXPOSE 8483
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:${MCL_HEALTH_PORT}/health" || exit 1

CMD ["/app/bin/mcl_victron", "foreground"]
