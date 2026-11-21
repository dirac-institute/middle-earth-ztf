#!/bin/bash
# Start the website locally for development, against a small fake archive.
#
#   ./dev-startup.sh
#
# There is no /root/VM.set and no /service/shire on a laptop, so this runs
# the web container as you (your own uid/gid) with a fixture directory from
# tests/make_fixture.sh in place of the real data. The partnership login is
# ztf / fixture-password.
#
# The archivist is not started: it needs the Kafka broker, which only admits
# allowlisted addresses. Its scripts are tested in the ztf-go-archivist repo
# (make test).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

export SVC_USER=dev-svc
export SVC_UID="$(id -u)"
export SVC_GID="$(id -g)"
export SVC_FQDN=localhost
export ZTF_DATA_ROOT="$PWD/.dev-data"

[ -d "$ZTF_DATA_ROOT" ] || tests/make_fixture.sh "$ZTF_DATA_ROOT"

docker compose up -d --build web
echo
echo "Running at http://localhost:8080/"
echo "Check it with: tests/web_test.sh http://localhost:8080"
echo "Stop with: docker compose down"
