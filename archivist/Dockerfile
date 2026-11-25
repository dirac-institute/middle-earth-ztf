# ZTF alert archivist: reads each night's alerts from Kafka and writes one
# gzipped tarball per program. The Go program and the scripts that run it
# come from github.com/ZwickyTransientFacility/ztf-go-archivist at a pinned
# commit; nothing in this directory is application code.

# The commit to build. To deploy a change to the archivist or its scripts,
# push it there and change this line.
ARG ARCHIVIST_REPO=https://github.com/ZwickyTransientFacility/ztf-go-archivist.git
ARG ARCHIVIST_COMMIT=5c8c0c7d1701b79672810a2dd6aa0ce4034cd908

# ── Build ───────────────────────────────────────────────────────────────────
# CGO off gives static binaries that run on any base image.
FROM docker.io/library/golang:1.23-bookworm AS build
ARG ARCHIVIST_REPO
ARG ARCHIVIST_COMMIT
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
RUN git clone "${ARCHIVIST_REPO}" . && git checkout --detach "${ARCHIVIST_COMMIT}"
RUN go build -o /out/ztf-go-archivist . && \
    install -m 0755 run_archivist.sh rerun_archivist.sh nightly.sh /out/
# supercronic: cron for containers. Runs as an ordinary user, logs to stdout,
# and does not start a job while its previous run is still going.
RUN GOBIN=/out go install github.com/aptible/supercronic@v0.2.33

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

COPY --from=build /out/ /usr/local/bin/
COPY crontab /etc/ztf-archivist.crontab
RUN supercronic -test /etc/ztf-archivist.crontab

# Full path, not a bare name: as PID 1, supercronic re-executes itself as a
# child (it stays behind to reap zombies) using argv[0], which is not looked up
# on PATH. With a bare "supercronic" that fails with "Failed to fork exec: no
# such file or directory" and the container restarts in a loop.
CMD ["/usr/local/bin/supercronic", "/etc/ztf-archivist.crontab"]
