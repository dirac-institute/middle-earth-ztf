# ZTF alert archive

The public archive of [Zwicky Transient Facility](https://www.ztf.caltech.edu)
alerts, served at <https://ztf.uw.edu/alerts/public/> and, for ZTF partnership
members, <https://ztf.uw.edu/alerts/partnership/>. One gzipped tarball per
night per program, each holding that night's alerts as individual Avro files.

This repo deploys it on a UW DiRAC service VM. It was ported from epyc in
late 2026 and follows the
[middle-earth-service-example](https://github.com/dirac-institute/middle-earth-service-example)
pattern: clone, `sudo ./init.sh`, `podman compose up -d --build`.

## What runs

| Container | What it does |
|---|---|
| `web` | Apache on `127.0.0.1:8080`. Serves the landing page and the directory listings of the two archives. The VM's reverse proxy terminates TLS in front of it. |
| `archivist` | At 00:10 Pacific every night, reads the night's alerts from the ZTF Kafka broker for 7 hours and writes `ztf_public_YYYYMMDD.tar.gz` and `ztf_partnership_YYYYMMDD.tar.gz`. Also refills any night in the last week whose tarball is missing. |
| `monitoring` | Reports the VM's CPU, memory and disks to the DiRAC gadget monitor. Copied unchanged from the example. |

The archive itself (about 31 TB) is not in any container. It lives on the
service's NFS share, `/service/shire` on the VM, which is
`/astro/store/shire/@Service/ztf/data` on arnor, gondor and epyc.

```
/service/shire/
  alerts/public/        ztf_public_*.tar.gz, MD5SUMS
  alerts/partnership/   ztf_partnership_*.tar.gz, MD5SUMS
  secrets/              htpasswd, slack_webhook        (SECRETS.md)
  scratch/              the night's uncompressed tar while it is being written
  logs/                 one log per job per night, kept 90 days
```

## Where the code is

- **This repo**: the containers, the Apache configuration, the website's
  static files, deployment and cutover tooling.
- **[ztf-go-archivist](https://github.com/ZwickyTransientFacility/ztf-go-archivist)**:
  the Go program that reads Kafka and the shell scripts that run it nightly
  (`run_archivist.sh`, `rerun_archivist.sh`, `nightly.sh`). The archivist
  image builds that repo at the commit pinned in `archivist/Dockerfile`. To
  change how archiving behaves, change it there, run `make test`, push, and
  update the pin.

## Common tasks

Run these on the VM, in the repo directory.

**See whether last night worked.**

```bash
podman logs --since 24h ztf-alert-archive-archivist | grep nightly.sh
ls -l /service/shire/alerts/public | tail -3
```

Each job's full output is in `/service/shire/logs/<job>_<YYYYMMDD>.log`. If a
Slack webhook is configured, a failed night is posted there.

A 74-byte tarball is an empty night. That is normal when ZTF did not observe,
and it is also what a night looks like if the broker was unreachable in a way
that produced no error. The archivist cannot tell the two apart.

**Re-archive a night by hand.** A topic stays on the broker for a limited
time, so this only works for recent nights. (The rerunner looks back 7 days;
how long the broker really keeps a topic has not been checked.)

```bash
podman exec ztf-alert-archive-archivist run_archivist.sh programid1 20261201
```

`programid1` is public, `programid2` is partnership. It refuses if the
tarball already exists; add `--force` as the first argument to replace it. A
missing tarball from the last 7 days needs no action: the nightly job refills
it.

**Change the partnership password, or the Slack webhook.** See `SECRETS.md`.

**Deploy a change.** Commit it, then on the VM:

```bash
git pull
sudo ./init.sh
podman compose up -d --build --force-recreate
```

Without `--force-recreate` the existing containers keep running their old
images (DEPLOY.md, "Deploying a change"). Recreating restarts the archivist. Between 00:10 and about 07:30 Pacific that
kills the night in progress; the rerunner will pick the night up the
following night, but avoid it.

## Testing

- `tests/local_httpd_test.sh` runs the Apache configuration under a locally
  installed httpd against a small fake archive and checks its behaviour:
  listings, sort order, the partnership login, what must not be served.
- `tests/web_test.sh BASE_URL [USER:PASSWORD]` runs the same checks against
  any running copy, including the container (`./dev-startup.sh` starts one
  locally with docker) and the deployed site.
- The archiving scripts are tested in ztf-go-archivist (`make test`).

## Further reading

- `DEPLOY.md` — deploying to a VM, preparing the data directory, the cutover
  from epyc, and why things are the way they are.
- `SECRETS.md` — the two secrets and how to change them.
- `monitoring/README.md` — the service VM monitor.
- `docs/superpowers/specs/2026-11-20-ztf-alert-archive-port-design.md` — the
  design for the port, including a description of the system as it ran on
  epyc.
