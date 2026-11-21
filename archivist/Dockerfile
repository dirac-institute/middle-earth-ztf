# ZTF alert archivist: reads each night's alerts from Kafka and writes one
# gzipped tarball per program. The Go program and the scripts that run it
# come from github.com/ZwickyTransientFacility/ztf-go-archivist at a pinned
# commit; nothing in this directory is application code.

# The commit to build. To deploy a change to the archivist or its scripts,
# push it there and change this line.
ARG ARCHIVIST_REPO=https://github.com/ZwickyTransientFacility/ztf-go-archivist.git
ARG ARCHIVIST_COMMIT=5c8c0c7d1701b79672810a2dd6aa0ce4034cd908

# ── The archivist ───────────────────────────────────────────────────────────
# Go 1.14 is what the module declares and what built the binary that ran on
# epyc; newer toolchains reject its go.sum. CGO off gives a static binary
# that runs on any base image.
FROM docker.io/library/golang:1.14 AS archivist
ARG ARCHIVIST_REPO
ARG ARCHIVIST_COMMIT
WORKDIR /src
RUN git clone "${ARCHIVIST_REPO}" . && git checkout --detach "${ARCHIVIST_COMMIT}"
RUN CGO_ENABLED=0 go build -o /out/ztf-go-archivist . && \
    install -m 0755 run_archivist.sh rerun_archivist.sh nightly.sh /out/

# ── The scheduler ───────────────────────────────────────────────────────────
# supercronic: cron for containers. Runs as an ordinary user, logs to stdout,
# and does not start a job while its previous run is still going.
FROM docker.io/library/golang:1.23-bookworm AS supercronic
RUN CGO_ENABLED=0 GOBIN=/out go install github.com/aptible/supercronic@v0.2.33

# ── Runtime ─────────────────────────────────────────────────────────────────
FROM docker.io/library/debian:bookworm-slim

# curl posts failures to Slack; util-linux is flock; tzdata so the schedule
# can be in Pacific time.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl tzdata util-linux && \
    rm -rf /var/lib/apt/lists/*

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER
RUN groupadd -g ${SVC_GID} ${SVC_USER} 2>/dev/null || true && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -s /sbin/nologin ${SVC_USER} 2>/dev/null || true

COPY --from=archivist   /out/ /usr/local/bin/
COPY --from=supercronic /out/supercronic /usr/local/bin/supercronic
COPY crontab /etc/ztf-archivist.crontab
RUN supercronic -test /etc/ztf-archivist.crontab

CMD ["supercronic", "/etc/ztf-archivist.crontab"]
