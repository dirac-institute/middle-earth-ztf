# Deploying the ZTF alert archive to a DiRAC VM

Target: stock Rocky 10 VM on UW DiRAC infrastructure, with the service's NFS
share mounted at `/service/shire`. The VM provides a reverse proxy that
handles TLS termination and routes traffic to the `web` container on port
8080.

```bash
git clone https://github.com/dirac-institute/middle-earth-ztf.git /root/middle-earth-ztf
cd /root/middle-earth-ztf
sudo ./init.sh
podman compose up -d --build
```

`init.sh` stops with an explanation if the data directory is not ready. The
first time, work through "Preparing the data directory" below before running
it, and through "Cutover from epyc" for the order to do everything in.

Then verify:

```bash
podman ps                                   # three containers, all Up
ZTF_WEB_TEST_REAL=1 tests/web_test.sh http://localhost:8080 ztf:<partnership password>
podman logs ztf-alert-archive-archivist     # supercronic has read the crontab
curl -s http://localhost:9110/metrics | grep source_success
```

## What each piece does

| File | Role |
|---|---|
| `/root/VM.set` (not in the repo) | Written by IT when the VM is provisioned. The source of truth for the service account name, uid, and gid. |
| `init.sh` | Host-level only: reads the service account from `/root/VM.set` and checks it exists on the VM, installs podman + podman-compose, enables `podman-restart.service`, checks the data directory and creates `scratch/`, `logs/` and `secrets/` in it, writes `.env`. Idempotent; safe to re-run. |
| `compose.yaml` | Three services: `web`, `archivist`, `monitoring`. |
| `web/Dockerfile` | Apache httpd 2.4 with the site's static files and configuration. |
| `web/conf/httpd.conf` | The virtual host: landing page, the two archive aliases, what is hidden. |
| `web/conf/autoindex-*.conf` | How each listing looks (sort order, icons, header and footer). |
| `web/conf/partnership-auth.conf` | The partnership login. |
| `web/htdocs/` | The landing page at `/`. |
| `web/fancy-index/{public,partnership}/` | The listing theme: header and footer text, stylesheet, script, icons. Edit `header.html` here to change the text above a listing. |
| `archivist/Dockerfile` | Builds ztf-go-archivist at a pinned commit, plus the supercronic scheduler. |
| `archivist/crontab` | The nightly schedule. |
| `monitoring/` | Service VM monitor, copied unchanged from [middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor). See `monitoring/README.md`. |
| `tests/` | Website checks and the fixture they run against. |
| `tools/` | One-off helpers for the cutover. |
| `dev-startup.sh` | Runs the website locally with docker against a fixture. |
| `SECRETS.md` | The two secrets and how to change them. |

## Architecture

```
                   ┌──────────────────────────────────────────┐
  VM reverse  ──►  │  web (port 8080)                          │
  proxy :8080      │    /                    landing page      │
                   │    /alerts/public/      listing, open     │──ro──┐
                   │    /alerts/partnership/ listing, password │      │
                   └──────────────────────────────────────────┘      ▼
                                                            /service/shire (NFS)
                   ┌──────────────────────────────────────────┐   alerts/
  Kafka broker ◄── │  archivist (no listening ports)           │   secrets/
  partnership.     │    supercronic, 00:10 Pacific:            │──rw─▲ scratch/
  alerts.ztf.      │      nightly.sh → programid1, programid2, │       logs/
  uw.edu:9092      │                   rerunner                │
                   └──────────────────────────────────────────┘

  gadget monitor   ┌──────────────────────────────────────────┐
  (polls every ──► │  monitoring (port 9110)                   │
  minute) :9110    │    /metrics → this VM's CPU, memory,      │
                   │               disks, load                 │
                   └──────────────────────────────────────────┘
```

## Preparing the data directory

`/service/shire` already holds a copy of the archive made by IT with
`FetchFromEpyc` (`rsync -avSH epyc:/data2/epyc/data/ztf/alerts ./`), plus
`html/` and `htpasswd`. Three things have to happen before the first deploy.

**1. IT: make the service account the owner of the archive.** The copy kept
epyc's ownership: directories `ztf-archivist:astro-ztf` mode 2775, tarballs
`ztf-archivist:ztf-archivist` mode 664. The service account is not in
`astro-ztf`, so it can read everything and write nothing. Root on the VM
cannot fix this (`root_squash`); it has to be done as root on the file
server, where the share is `/data/shire/@Service/ztf/data`:

```bash
chown -R astro-ztfsvc /data/shire/@Service/ztf/data/alerts/public \
                      /data/shire/@Service/ztf/data/alerts/partnership
```

Group and modes can stay as they are. Any later re-sync from epyc must not
undo this: add `--no-owner --no-group`, or repeat the `chown` afterwards.

**2. Move the password file** to `secrets/htpasswd`, mode 600. See
`SECRETS.md`, "The partnership password". Optionally add
`secrets/slack_webhook`.

**3. Run `sudo ./init.sh`.** It creates `scratch/`, `logs/` and `secrets/`
as the service account if they are missing and checks all of the above.

Left in place and no longer used once this repo is deployed; remove them
after the cutover has been stable for a week:

- `html/` (the landing page is in `web/htdocs/`);
- `alerts/.git` and `alerts/.gitignore`;
- `alerts/*/fancy-index/` and `alerts/*/.htaccess*` (in `web/` now).
  Apache here ignores `.htaccess` files and serves the theme from the image.

Hidden `.ztf_*.tar.gz.OLD` files and the stray `.tar` files in the archive
directories are historical and are left alone. Dot-files are never served.

## Cutover from epyc

The danger in this cutover is quiet: an archivist that reads only part of the
stream, or reads nothing, still writes a valid tarball. The steps are ordered
so that each night is produced by exactly one trusted archivist and checked
before epyc is turned off.

**Before the first deploy**

1. On the VM, find its outbound address (`curl -s https://ifconfig.me` or ask
   IT) and add it to the Kafka broker's allowlist. Until that is done the
   archivist cannot connect.
2. Ask IT to re-run `FetchFromEpyc`, so the copy on shire is complete up to
   last night, and then do the ownership change above. Do this on the day of
   the first deploy. If nights from the last week are missing from shire,
   the VM's rerunner will fetch them from Kafka itself, which is harmless but
   means those nights were never compared with epyc's.
3. Move the password file. Deploy. Run the verification commands at the top.
   Check the site by the VM's own name from another machine.

**Parallel run** (at least three nights that have alerts)

epyc keeps archiving to `/epyc/data/ztf/alerts`; the VM archives to
`/service/shire/alerts`. They use different consumer groups
(`ztf-go-archivist` on epyc, `ztf-go-archivist-vm` here, set in
`compose.yaml`), so each reads the whole stream. **Never give the VM epyc's
group name while epyc's cron is enabled**: two consumers in one group split
the stream between them.

4. Each morning after about 07:30 Pacific, on epyc, compare the night:

   ```bash
   D=$(date -u +%Y%m%d)
   S=/astro/store/shire/@Service/ztf/data/alerts
   tools/compare_tarballs.sh /epyc/data/ztf/alerts/public/ztf_public_$D.tar.gz \
                             $S/public/ztf_public_$D.tar.gz
   tools/compare_tarballs.sh /epyc/data/ztf/alerts/partnership/ztf_partnership_$D.tar.gz \
                             $S/partnership/ztf_partnership_$D.tar.gz
   ```

   `SAME` is the result to want. The files are never byte-identical. The two
   archivers start and stop a few seconds apart, so a handful of alerts at
   the very end of a night on one side only is not alarming; hundreds, or one
   side empty, is.

**Cutover day** (after that morning's runs have finished on both)

5. Ask IT to disable the `ztf-archivist` crontab on epyc.
6. Copy from epyc the nights the VM did not make, without touching the ones
   it did. As a user who can write to the share (the service account on the
   VM, if it can reach epyc, otherwise IT), for each of `public` and
   `partnership`:

   ```bash
   rsync -av --ignore-existing --no-owner --no-group \
       --include='ztf_*.tar.gz' --exclude='*' \
       epyc:/data2/epyc/data/ztf/alerts/public/ /service/shire/alerts/public/
   ```

   One exception to "the VM's file wins": if for some night the VM's tarball
   is empty (74 bytes) and epyc's is not, replace it with epyc's.
7. Merge the checksums. epyc's `MD5SUMS` has lines for the nights just
   copied; the VM's has lines for its own. For each program:

   ```bash
   cd /service/shire/alerts/public
   scp epyc:/data2/epyc/data/ztf/alerts/public/MD5SUMS MD5SUMS.epyc
   cat MD5SUMS.epyc MD5SUMS > MD5SUMS.merged     # the VM's lines last, so they win
   mv MD5SUMS.merged MD5SUMS
   /root/middle-earth-ztf/tools/normalize_md5sums.sh MD5SUMS
   rm MD5SUMS.epyc
   ```

   This also converts the old `/epyc/data/ztf/alerts/...` paths to bare
   filenames. Spot-check a recent night: `md5sum -c MD5SUMS 2>/dev/null |
   tail -3` (it reads whole tarballs; interrupt it when satisfied). About
   400 old tarballs per program have never had a line and still will not.
8. Ask IT to point `ztf.uw.edu` at the VM's reverse proxy, with a
   certificate for that name. Then, from outside UW:

   ```bash
   ZTF_WEB_TEST_REAL=1 tests/web_test.sh https://ztf.uw.edu ztf:<password>
   ```

   and download one multi-GB tarball in full and check it against `MD5SUMS`.
   This is the test of the proxy's timeouts and size limits.
9. Register the VM with the gadget monitor (below).

**A week later**, if every night has arrived: remove the unused files listed
under "Preparing the data directory", and ask IT to retire the `ztf.uw.edu`
virtual host and the `ztf-archivist` account on epyc.

The VM keeps the group name `ztf-go-archivist-vm`. There is nothing to
switch back: every night is a new topic, read from its first offset.

### What did not move

- `https://ztf.uw.edu/jupyter/`, a proxy to a JupyterHub on epyc, was on the
  same virtual host. It is not part of this service. After the DNS change
  that URL returns 404.
- `programid3`. epyc had not archived it since 2020.
- Email from cron on failure. Replaced by the Slack webhook.

## Design choices

**Three containers, one share.** The website and the archiver have nothing
in common except the directory one writes and the other serves, so they are
separate containers with separate mounts: read-only for `web`, read-write
for `archivist`.

**The data directory holds data only.** On epyc, the listings' appearance and
the partnership login were `.htaccess` files inside the archive directories,
next to a copy of the index theme. Here all of that is in `web/`, baked into
the image, and Apache runs with `AllowOverride None`. A stray or edited file
in the archive cannot change who may read it.

**Dot-files are never served, even with the partnership password.** The
archiver writes each tarball as `.tmp.<name>` and renames it when complete,
so nobody can download half a night. The login is configured per
`<Directory>`, not per `<Location>`, because a `<Location>` is applied last
and would let a valid password override the dot-file rule.

**No redirect for a missing trailing slash.** `/alerts/public` is answered
with the listing itself (`DirectorySlash Off`) and the theme's `header.html`
carries a `<base href>` so its links resolve. Apache sits behind the VM's
TLS proxy and does not know the public scheme or port; a redirect it built
would point at `http://...:8080`.

**A failed night publishes nothing.** If the archivist exits with an error,
no tarball is written, the nightly job exits non-zero and posts to Slack, and
the rerunner tries that night again on each of the next 7 nights. On epyc a
failed run left an empty or truncated tarball that was never retried. What
this cannot catch is a run that hears nothing and exits cleanly: that is
indistinguishable from a night with no observing.

**Past nights are quick to re-read.** A run for a date other than today uses
a fresh consumer group, so it starts from the beginning of the topic, and
stops after 10 quiet minutes rather than 7 quiet hours. The scheduler does
not start a night while the previous night's job is still running, so slow
reruns would cost new nights.

**No overwriting.** `run_archivist.sh` refuses to replace an existing
tarball without `--force`.

**Scratch and logs are on the share.** The uncompressed tar of a busy night
is tens of GB. Leftover scratch directories from a killed run are removed
the next night once they are a day old; logs are kept 90 days.

**Schedule in Pacific time.** 00:10 `America/Los_Angeles`, as on epyc.

**Service account with fixed uid/gid, port 8080 on localhost only,
monitoring on 9110.** As in the example repo; see its `DEPLOY.md` for the
reasoning. `.env` is written by `init.sh` from `/root/VM.set` on every run
and carries `SVC_USER`, `SVC_UID`, `SVC_GID`, `SVC_FQDN` and
`ZTF_DATA_ROOT`. Do not edit it or copy it between hosts. To deploy against
a test copy of the data, run `sudo ZTF_DATA_ROOT=/some/dir ./init.sh`.

## Monitoring

The `monitoring` container is the gadget monitor's **service VM monitor**. It
serves the VM's CPU, memory, disk and load figures as Prometheus text on
`http://<vm fqdn>:9110/metrics`. **Keep `monitoring/` identical to the gadget
monitor's copy**; to update it, copy the folder over again from
[middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor).
Port 9110 is published on every interface and does not go through the VM's
proxy. `monitoring/README.md` has the details.

It reports the VM's local disks only. It does not watch the NFS share and
does not know whether last night's tarball arrived; that is what the Slack
webhook is for.

### Registering the VM with the gadget monitor

Once the service is running on its production VM:

1. From another machine: `curl -s http://<vm fqdn>:9110/metrics | grep
   source_success`. Every `source` should report `1`.
2. Open a pull request against
   [dirac-institute/middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor)
   adding one entry to `config/service_vms.toml`:

   ```toml
   [[service_vm]]
   name = "ztf"                # choose once; renaming breaks the history
   address = "<vm fqdn>"       # the production VM's own FQDN, not ztf.uw.edu
   ```

   Give this repo and paste the step 1 output in the PR description.
3. After it merges and the gadget monitor is redeployed, the VM appears on
   the **Service VMs** dashboard within a minute or two.

## Boot persistence

`restart: unless-stopped` only survives reboot if `podman-restart.service` is
enabled, which `init.sh` does. A reboot during the night kills that night's
run; the rerunner refills it the following night.
