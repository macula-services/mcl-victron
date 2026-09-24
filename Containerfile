# mcl-victron
#
# Victron GX telemetry (dbus-flashmq MQTT on the LAN), recorded in the service's
# own reckon-db store on the /data volume and published on the mesh.
#
# ⚠ THE TEAM IMAGE PAIR, PINNED BY DATED TAG AND DIGEST. macula-ci-otp builds
# (OTP 28.4.3 on an OpenSSL with ML-DSA, rebar3, Rust, cmake); the release
# runs on macula-pq-runtime, the same Debian trixie, so its ERTS and NIFs match
# the libc they run on. The runtime is pinned in four places and they must
# agree: the builder's RUN check below, `.github/workflows/lint-and-test.yml'
# (the same build image), `.tool-versions', and the VM the suite runs on;
# mcl_victron_service_tests compares all four and holds both digests. A
# floating `erlang:28-alpine' shipped OTP 28.5 to the fleet on 2026-09-22.
FROM ghcr.io/macula-io/macula-ci-otp:20260923-1444@sha256:dd2ba6eb858a0eacedf0179300323fe5c6da46fb308d22da0ca8cfcd1f0718dc AS builder

# The OTP release, asserted here because the image tag names a date.
RUN erl -noshell -eval ' \
    Otp = string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])))), \
    Mldsa = lists:member(mldsa87, crypto:supports(public_keys)), \
    io:format("OTP ~s, mldsa87 ~p~n", [Otp, Mldsa]), \
    case {Otp, Mldsa} of \
        {<<"28.4.3">>, true} -> halt(0); \
        _                    -> halt(1) \
    end.'

WORKDIR /build

# Dependencies resolve from rebar.config alone, so this layer survives every
# change to config/ and apps/.
COPY rebar.config ./
RUN rebar3 get-deps

COPY config ./config
COPY apps ./apps
RUN rebar3 as prod release

FROM ghcr.io/macula-io/macula-pq-runtime:20260923-1444@sha256:15a5501b7277804c5a62c93121d157773d1401d238a1bf630ef4b50fc2f1df09
# LINKS THE PACKAGE TO THE REPOSITORY, so ghcr shows it there and it inherits
# the repository's visibility.
LABEL org.opencontainers.image.source="https://github.com/macula-services/mcl-victron"
# The commit this image was built from (build-push passes github.sha), so a
# digest a fleet pins can be traced back to its commit.
ARG REVISION=unknown
LABEL org.opencontainers.image.revision="${REVISION}"
# The runtime image carries what the release loads: libstdc++ and libgcc for
# the NIFs, OpenSSL 3 for OTP's crypto, ncurses, CA certificates, and curl for
# the health check.
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
