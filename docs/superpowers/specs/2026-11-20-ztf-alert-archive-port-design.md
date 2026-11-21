# ZTF alert archive: port to the DiRAC VM infrastructure

Date: 2026-11-20. Status: draft for review by Eric Bellm.

## Intent

The ZTF alert archive is a nightly job that saves the ZTF Kafka alert stream
to one gzipped tarball per night per program, plus a website that serves those
tarballs. Both run on epyc today, as a user crontab and as part of epyc's
shared Apache. epyc is being retired as a service host. This project moves
both pieces onto a DiRAC service VM, deployed from this repo the same way as
every other Middle-earth service: clone, `sudo ./init.sh`,
`podman compose up -d --build`.

Success means: external users see the same URLs, the same listings and the
same files; a tarball for every night keeps appearing with no gap across the
cutover; and nothing about the service lives only on a host.

## Legacy system (as found on epyc, 2026-11-20)

### Nightly archiver

- Code: `/epyc/projects/ztf-go-archivist/`. `src/` is a checkout of
  `github.com/ZwickyTransientFacility/ztf-go-archivist` at commit `aa04f6d`
  ("build v4.02 schema") on branch `u/ebellm/v4_schema`, which is pushed to
  origin. It is **not** on `master` (`a3cc55e`). The running binary
  `bin/ztf-go-archivist` was built from it on 2023-10-11.
- Schedule: crontab of local user `ztf-archivist` (uid 1003, exists only on
  epyc), `10 0 * * *` in Pacific time, runs `etc/nightly`. `MAILTO` sends
  cron output to ecbellm and chrisp79.
- `etc/nightly` starts three background jobs and waits for all of them:
  - `bin/run_archivist.sh programid1` → public
  - `bin/run_archivist.sh programid2` → partnership
  - `bin/rerun_archivist.sh` → for each of the previous 7 UTC days and each
    program, if the tarball file does not exist, run `run_archivist.sh` for
    that day, sequentially, under a fresh consumer group named
    `ztf-go-archivist-rerun2-YYYYMMDD`.
- `run_archivist.sh PROGRAMID [DATE]`:
  - `DATE` defaults to today's UTC date, `YYYYMMDD`.
  - Topic is `ztf_${DATE}_${PROGRAMID}`.
  - Runs `ztf-go-archivist -broker=partnership.alerts.ztf.uw.edu:9092
    -group=${ZTF_ARCHIVIST_GROUP:-ztf-go-archivist} -topic=... -dest=<tmp tar>`.
    The same broker serves both programs.
  - The binary reads from the first offset, writes one `<candid>.avro` tar
    entry per alert, and exits 0 after `-max-runtime` (default 7h) or after
    `-max-quiet-period` (default 7h) of silence. On a Kafka error it exits
    non-zero.
  - The temporary uncompressed tar goes in a `mktemp -d` directory under
    `/epyc/ssd/tmp`. Then `gzip --best` to a temp file, `mv` to
    `/epyc/data/ztf/alerts/{public,partnership}/ztf_{public,partnership}_${DATE}.tar.gz`,
    append `md5sum` output to `MD5SUMS` in the same directory, remove the temp
    directory.
- Logs: appended forever to `log/ztf-go-archivist_{programid1,programid2,rerunner}.log`
  (over 200 MB each; a progress line every 10 seconds).
- Typical sizes: 1–10 GB per gzipped tarball; an empty night is a valid
  74-byte tarball. About 3,100 public and 3,070 partnership tarballs, 31 TB.

Known defects in the deployed scripts:

- The deployed `bin/run_archivist.sh` has lost its first lines: it begins
  `et -eo pipefail`, so there is no shebang and no `set -e`. When the binary
  fails (38 fatal Kafka timeouts in the public log), the script carries on and
  publishes a truncated or empty tarball with an MD5 line. Because the file
  then exists, the rerunner never retries that night.
- `etc/nightly` tests the literal string `"PROGRAMID1_EXITCODE"` rather than
  the variable, so its failure report never fires.
- A rerun appends a second `MD5SUMS` line for the same file.

### Website

- `ztf.uw.edu` resolves to epyc (128.95.0.72). epyc's Apache 2.4.6 has a
  `ztf.uw.edu` vhost in `/etc/httpd/conf.d/ssl.conf`:
  - `DocumentRoot /var/www/ztf.uw.edu/html` — a static landing page
    (`index.html` from an HTML template, with a "Data Access" button linking
    to `alerts/public`). The directory also holds unused template leftovers
    (stock photos, `inc/sendEmail.php`, `styles.html`, `readme.txt`).
  - `Alias /alerts/public /epyc/data/ztf/alerts/public` and the same for
    `partnership`, each with `AllowOverride All`,
    `Options Indexes MultiViews FollowSymLinks`, `Require all granted`.
  - A `/jupyter` reverse proxy to a JupyterHub on epyc.
- All behaviour of the two alert directories comes from an `.htaccess` file
  inside each data directory:
  - `Options +Indexes`, fancy auto-index (`IndexOptions IgnoreCase
    FancyIndexing HTMLTable SuppressHTMLPreamble FoldersFirst VersionSort
    NameWidth=* DescriptionWidth=* XHTML IconHeight=16 IconWidth=16`),
    `IndexOrderDefault Descending Name`, header/footer/stylesheet/icons from
    a `fancy-index/` subdirectory of that same data directory (a copy of the
    "Apache fancy index" theme, with the ZTF text in `header.html` and
    `footer.html`), `IndexIgnore` for `..`, `fancy-index`, `.git` and
    friends.
  - Apache 2.2-style `order allow,deny` / `deny from all` blocks hiding
    `.ht*` and all dot-files.
  - Partnership only: `AuthType Basic`, `AuthName "Access for ZTF Partnership
    Members Only"`, `AuthUserFile /var/www/ztf.uw.edu/htpasswd`,
    `Require valid-user`. The htpasswd file has a single user, `ztf`.
- The public and partnership `fancy-index/` copies differ in `header.html`,
  `footer.html`, `script.js` and `style.css`.
- `/epyc/data/ztf/alerts/` is itself a git repo (by mjuric) tracking the
  `.htaccess` files and `fancy-index/`.
- The directories also contain `MD5SUMS` (served, and users rely on it),
  `VALIDATE` / `VALIDATE.out`, editor backups (`.htaccess~`, `.htaccess.bak`),
  a few hidden `.ztf_*.tar.gz.OLD` files and one stray uncompressed `.tar`.

## Target environment

- A Rocky 10 DiRAC service VM with podman and podman-compose. The VM's own
  reverse proxy terminates TLS and forwards to the container on
  `127.0.0.1:8080`. IT provisions the service account and `/root/VM.set`.
- Service account: `astro-ztfsvc`, uid 1734448, gid 2121734448. It is not a
  member of group `astro-ztf` (gid 705884).
- Data: `/service/shire/` inside the VM, which is
  `/astro/store/shire/@Service/ztf/data/` on arnor/gondor/epyc. NFS, exported
  with `root_squash`. 116 TB free on the filesystem. It currently holds:
  - `alerts/` — an rsync of the epyc tree taken 2026-10-26 (stale; epyc has
    kept writing since). Directories are `ztf-archivist:astro-ztf` mode 2775;
    tarballs are `ztf-archivist:ztf-archivist` mode 664. So `astro-ztfsvc`
    can read everything but cannot create files in `public/` or
    `partnership/` or append to `MD5SUMS`.
  - `html/` — copy of the landing page directory, owned by `astro-ztfsvc`,
    with an added symlink `html/alerts -> ../alerts/`.
  - `htpasswd` — the partnership password file, `astro-ztfsvc`, mode 644.
  - `FetchFromEpyc` — IT's one-line rsync, root-owned:
    `rsync -avSH epyc:/data2/epyc/data/ztf/alerts ./`.
- Eric controls the Kafka broker's IP allowlist and will add the VM.
- Eric has login credentials for the VM. Nothing has been inspected on the VM
  yet: its hostname, local disk size and outbound IP are unknown.

## Goals

1. Nightly archiving of `programid1` and `programid2` runs on the VM and
   produces tarballs with the same names, layout and contents as today.
2. `https://ztf.uw.edu/`, `/alerts/public/` and `/alerts/partnership/` behave
   as they do today: same landing page, same listing appearance and sort
   order, same file URLs, partnership behind the existing username and
   password.
3. The repo is the deployment. It follows the template's rules: `init.sh`
   does host-level work only, everything else is in containers, secrets are
   bind-mounted, the service account comes from `/root/VM.set`, the
   `monitoring/` folder is unchanged.
4. A failed night is retried automatically rather than published as an empty
   tarball.
5. No gap and no corrupted night across the cutover from epyc.

## Non-goals

- The `/jupyter` JupyterHub proxy on the `ztf.uw.edu` vhost. Not ported.
- `programid3`. Not run today, not ported.
- Changing the tarball format, the Go program's logic, or the Kafka library.
- Reorganising or re-validating the 31 TB of historical tarballs.
- Cron-style email on failure. Failures are visible in logs only (see "Left
  open").

## Anti-goals

- Two archivers consuming under the same Kafka consumer group at once. They
  would split the stream and both produce incomplete tarballs that look fine.
- Any run that publishes a partial tarball under the final filename.
- Web-server configuration or secrets living in the data directory, where the
  web container could serve or the archiver could overwrite them.
- Manual fixes on the VM that are not in the repo.

## Design

### Containers

`compose.yaml` defines three services, all running as
`${SVC_UID}:${SVC_GID}`:

| Service | Image | Mounts | Network |
|---|---|---|---|
| `web` | httpd 2.4 | `/service/shire/alerts` → read-only; htpasswd secret read-only | `127.0.0.1:8080:8080` |
| `archivist` | Go binary + scripts + scheduler | `/service/shire/alerts` read-write; scratch; logs | outbound to the broker only, no published ports |
| `monitoring` | from `monitoring/`, unchanged | as in the template | `9110:9110` |

The template's Flask app, `start.sh`, gunicorn and the `/api/` proxy are
removed. Container names and `idac.service` labels use the prefix
`ztf-alert-archive`.

### Web container

- Apache listens on 8080, plain HTTP, `ServerName ${SVC_FQDN}`.
- Document root is the landing page, baked into the image from the repo:
  `index.html`, `css/`, `js/`, `fonts/`, the favicons and only the images
  that `index.html` and its CSS reference. The PHP mailer, `styles.html`,
  `readme.txt` and the stock template images are dropped.
- `Alias /alerts/public` and `/alerts/partnership` point at the read-only
  data mount.
- `AllowOverride None`. Everything the two `.htaccess` files did is
  translated into the repo's Apache config in 2.4 syntax (`Require all
  denied` in place of `order`/`deny`): the index options and sort order, the
  icon and description mappings, the dot-file and `.ht*` denial, and the
  partnership basic auth with the same `AuthName`.
- The fancy-index theme is baked into the image, one copy per program
  because they differ, and served at the same URLs as today
  (`/alerts/public/fancy-index/...`, `/alerts/partnership/fancy-index/...`)
  by more specific aliases. The existing `header.html`, `footer.html`,
  `script.js` and `style.css` are carried over as they are in the shire copy
  (including mjuric's uncommitted `public/fancy-index/header.html` edit).
- Listings hide `fancy-index`, `VALIDATE*`, editor backups and dot-files.
  `MD5SUMS` stays listed and downloadable.
- Range requests and large-file downloads must work through the VM's proxy;
  this is a test item, not something the container configures.
- Access and error logs go to the container's stdout/stderr.

### Archivist container

- Multi-stage build. Stage one clones
  `github.com/ZwickyTransientFacility/ztf-go-archivist` at the pinned commit
  `aa04f6d7a5ada779bf786d213e8bfea31ef3b033` and runs `go build`. Stage two
  is a small Debian image with the binary, `bash`, `gzip`, `coreutils`,
  `tzdata` and a scheduler.
- The shell scripts were never committed upstream in
  their deployed form and are rewritten from the legacy ones.  Commit these fixes to the upstream repo:
  - `run_archivist.sh PROGRAMID [DATE]` — same interface, topic naming,
    broker, group override and output names. Changes from legacy:
    - proper shebang, `set -euo pipefail`;
    - if the binary exits non-zero, nothing is published, the scratch
      directory is removed, and the script exits non-zero;
    - gzip writes to a hidden temp name on the destination filesystem and is
      renamed into place, so a reader never sees a partial file;
    - `MD5SUMS` is updated by replacing any existing line for that filename,
      not appending a duplicate. New lines use the bare filename
      (`<md5>  ztf_public_YYYYMMDD.tar.gz`), so `md5sum -c` works from inside
      the directory. Legacy lines are mixed: bare names up to about 2020,
      then `/epyc/data/ztf/alerts/...` absolute paths;
    - it refuses to replace a tarball that already exists unless given
      `--force`. Legacy `mv` overwrote silently;
    - a run for a past date (a `DATE` argument other than today's UTC date)
      always uses a fresh consumer group, so it reads from the first offset
      rather than from where an earlier run stopped, and passes a short
      `-max-quiet-period` (10 minutes). A past night's topic is complete, so
      there is no reason to wait 7 hours after its last message. Legacy
      reruns each took about 7 hours for this reason;
    - all paths, the broker and the group come from environment variables
      with defaults set in `compose.yaml`.
  - `rerun_archivist.sh` — same 7-day look-back, sequential, fresh consumer
    group per run. With the short quiet period above, a rerun takes about as
    long as reading and compressing the night, so a full 14-tarball backfill
    fits well inside a day. This matters because the scheduler does not
    start a night while the previous night's job is still running: under the
    legacy 7-hours-per-rerun timing, three missing tarballs would make the
    next night be skipped.
  - `nightly.sh` — starts the two program runs and the rerunner in parallel
    as today, waits, reports each exit code correctly, exits non-zero if any
    failed.
- Schedule: `10 0 * * *` in `America/Los_Angeles`, as today, using
  `supercronic` as the container's main process (runs as a non-root user,
  logs to stdout, does not overlap a still-running job).
- Scratch: `/service/shire/scratch/`. The uncompressed tar is tens of GB per
  program and the VM's local disk size is unknown; shire has room and is the
  same filesystem as the destination. On start, the nightly script removes
  scratch directories left by a killed run.
- Logs: `/service/shire/logs/`, one file per program per run date
  (`programid1_20261120.log`), also echoed to container stdout. Files older
  than 90 days are deleted by the nightly script.
- A run that is killed mid-way (VM reboot, container restart) leaves no
  tarball; the rerunner picks that night up on a later night, as long as the
  topic is still within the broker's retention.
- A manual run is `podman exec <container> run_archivist.sh programid1
  20261119`.

### Data directory layout on `/service/shire`

```
/service/shire/
  alerts/public/        tarballs, MD5SUMS            (web ro, archivist rw)
  alerts/partnership/   tarballs, MD5SUMS            (web ro, archivist rw)
  secrets/htpasswd      0600 astro-ztfsvc            (web ro)
  scratch/                                           (archivist rw)
  logs/                                              (archivist rw)
```

One-time massaging, documented in `DEPLOY.md` as a checklist:

- IT (root on shire) changes the owner of `alerts/public`,
  `alerts/partnership` and everything in them to `astro-ztfsvc`. Group and
  modes stay as they are.
- `htpasswd` moves to `secrets/htpasswd`, mode 0600.
- `html/`, `alerts/.git`, `alerts/.gitignore`, both `fancy-index/`
  directories and both `.htaccess` files are no longer used once their
  content is in this repo. They are left in place until after cutover, then
  removed. The hidden `.OLD` tarballs and the stray `.tar` are left alone.

### Secrets

Only one: the partnership `htpasswd`. It is bind-mounted read-only into the
web container, never copied into the image or the repo. `SECRETS.md` is
rewritten to describe it, including how to change the password.

### Repo contents

Rewritten for this service: `README.md`, `DEPLOY.md`, `SECRETS.md`,
`compose.yaml`, `apache/`, `dev-startup.sh`. New: `web/` and `archivist/`
build contexts. `init.sh` keeps its template behaviour and additionally
checks that `/service/shire/alerts/{public,partnership}`, `scratch`, `logs`
and `secrets/htpasswd` exist and are writable or readable by the service
account as required, failing with a message that says what to ask IT for.
`monitoring/` is untouched.

Local development (`dev-startup.sh`) runs the web container against a small
fixture directory of fake tarballs so the listing and auth can be checked
without the VM. The archivist is not started locally by default.

### Testing

- Shell tests for `run_archivist.sh` and `rerun_archivist.sh` with a stub
  binary on `PATH`: success publishes tarball and one MD5 line; failure
  publishes nothing; rerun replaces the MD5 line; rerunner selects exactly
  the missing nights.
- Web container tests against the fixture directory: public listing 200 and
  sorted newest first; partnership 401 without credentials and 200 with;
  `.htaccess`, dot-files and `.git` return 403/404; `MD5SUMS` downloads;
  a `Range` request returns 206.
- On the VM: the template's deployment checks (containers up, no restart
  loop, monitoring endpoint, reboot survival), plus the parallel-run
  comparison below.

### Cutover

1. Eric adds the VM's outbound IP to the broker allowlist.
2. IT re-runs `FetchFromEpyc` so shire is current to the previous night,
   then does the ownership change. Deploy on the VM the same day, so the
   rerunner finds nothing to backfill on its first night. (Without the
   re-sync it would see all 7 look-back days missing for both programs and
   backfill them from Kafka, and those files would then count as
   VM-produced.) The web container serves the copy; check it by the VM's own
   hostname.
3. Parallel run: the VM archivist runs nightly with
   `ZTF_ARCHIVIST_GROUP=ztf-go-archivist-vm` (a different group from epyc's
   `ztf-go-archivist`), writing into the real `alerts/` directories on shire.
   For at least three nights with data, compare each VM tarball with epyc's
   for the same night: same number of entries and same set of `candid`
   names. Byte-identical files are not expected, because tar entry
   timestamps are the time of writing.
4. Cutover day, after the epyc run has finished (after about 07:30 Pacific):
   disable the `ztf-archivist` crontab on epyc; rsync from epyc to shire the
   nights that the VM did not produce, without overwriting VM-produced
   files, with one exception: where the VM's tarball for a night is empty
   and epyc's is not, epyc's wins. Then normalise `MD5SUMS` on shire: strip
   the `/epyc/data/ztf/alerts/<program>/` prefix from every line, keep the
   last line for each filename, sort by filename. No checksums are computed
   for the roughly 400 historical tarballs per program that never had a
   line; that would mean reading several TB and falls under the
   "no re-validating history" non-goal.
5. IT points `ztf.uw.edu` at the VM's reverse proxy. Check all three URLs
   and a large download from outside UW.
6. Register the VM with the gadget monitor, per `DEPLOY.md`.
7. After a week of clean nights: remove the unused files listed above, and
   retire the epyc vhost and crontab for good.

The VM keeps the group name `ztf-go-archivist-vm` permanently. There is no
reason to switch back to the old name: each night is a new topic read from
its first offset.

## Decisions and who made them

Eric's:

- Port both the cron job and the website, using this repo as the base.
- Data lives under `/service/shire/`.
- Eric manages the broker allowlist.

Claude's calls, open to correction:

- Three containers rather than cron on the VM host.
- `.htaccess` logic and fancy-index assets move into the repo and image;
  `AllowOverride None`.
- Go binary built from the pinned upstream commit in the image; wrapper
  scripts live in this repo.
	* Eric: instead, push fixes to the upstream ztf-go-archivist repo
- Failed runs publish nothing; `MD5SUMS` lines are replaced, not duplicated.
- `MD5SUMS` uses bare filenames from now on, and existing lines are
  normalised to match at cutover.
- No overwrite of an existing tarball without `--force`.
- Past-date runs use a fresh consumer group and a 10-minute quiet period.
- Shire is re-synced from epyc immediately before the first VM run.
- Scratch and logs on shire; per-run logs with 90-day retention.
- Schedule stays at 00:10 Pacific; `supercronic` as scheduler.
- `/jupyter` and `programid3` are dropped.
- Parallel run under a separate consumer group that then becomes permanent.
- Landing page trimmed to what `index.html` uses.

## Left open

- **Failure alerting.** Cron's email goes away. This design logs failures
  and exits non-zero but notifies no one. Options later: a status file the
  gadget monitor can read, or a Slack webhook (which would be a second
  secret).
	** Eric: let's add a Slack webhook.
- **VM facts**, to be read off the VM at the start of implementation:
  hostname/FQDN, outbound IP, local disk size, whether `/service/shire` is
  mounted, and whether the VM proxy imposes a request timeout or size limit
  that would break multi-GB downloads.
- **Broker retention.** The rerunner assumes a topic is still readable for up
  to 7 days. Not verified from the broker side.

## Left to the builder

- Exact Apache directive layout and file names under `web/`.
- Base image tags and the Go toolchain version (the module is `go 1.14` with
  `kafka-go v0.3.5`; use the newest toolchain that builds it unmodified).
- The test harness (bats or plain bash) and fixture layout.
- Wording of `README.md`, `DEPLOY.md`, `SECRETS.md`.
