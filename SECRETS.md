# Secrets

No secret is ever committed to this repo or baked into a container image.

The service has two. Both are files in `/service/shire/secrets/`, which
`compose.yaml` bind-mounts read-only at `/run/secrets` in the `web` and
`archivist` containers.

| File | Used by | Required | What it is |
|---|---|---|---|
| `htpasswd` | `web` | yes | The username and password for `/alerts/partnership/`. Apache htpasswd format, one user (`ztf`), shared by all ZTF partnership members. |
| `slack_webhook` | `archivist` | no | A Slack webhook URL, on one line: an incoming webhook or a Workflow Builder trigger (see below). When a nightly job fails, `nightly.sh` posts which job failed and the last lines of its log. Without the file, failures are only logged. |

```
/service/shire/secrets/                 0755  $SVC_USER
/service/shire/secrets/htpasswd         0600  $SVC_USER
/service/shire/secrets/slack_webhook    0600  $SVC_USER
```

`init.sh` creates the directory, refuses to continue without a readable
`htpasswd`, and warns if `slack_webhook` is absent.

## Ownership and root_squash

`/service/shire` is exported with `root_squash`, so **root on the VM cannot
write to it** — root is mapped to `nobody`. `secrets/` is owned by the
service account named in IT's `/root/VM.set` (`VMUSER`, `VMUID`, `VMGID`),
which `init.sh` also writes to the repo's `.env` as `SVC_USER`, `SVC_UID`,
`SVC_GID`. The containers run as that uid, which is why they can read
mode-0600 files there. (The archive itself is shared through a group instead;
see DEPLOY.md, "Preparing the data directory".)

To place or update a secret, write it as that user. The service account
cannot read `/root` (mode 550), so it cannot copy a file from there itself:
let root open the file and hand it over on stdin. The commands below use the
`SVC_*` names; in bash, `source .env` in the repo directory first to set
them.

```bash
sudo -u $SVC_USER sh -c 'umask 077 && cat > /service/shire/secrets/<name> &&
    chmod 600 /service/shire/secrets/<name>' < /path/to/file
```

If the account is not available by name, use the numeric ids:

```bash
setpriv --reuid=$SVC_UID --regid=$SVC_GID --clear-groups sh -c 'umask 077 &&
    cat > /service/shire/secrets/<name> &&
    chmod 600 /service/shire/secrets/<name>' < /path/to/file
```

Secrets are URLs and passwords: don't `cat` them to the terminal to check
them. `sudo -u $SVC_USER wc -c /service/shire/secrets/<name>` shows the file
is there and not empty.

## The partnership password

**First deployment.** The existing file was copied from epyc to
`/service/shire/htpasswd`, mode 644. Move it into place and tighten it:

```bash
sudo -u $SVC_USER sh -c '
    mkdir -p /service/shire/secrets &&
    mv /service/shire/htpasswd /service/shire/secrets/htpasswd &&
    chmod 600 /service/shire/secrets/htpasswd'
```

**Changing it.** The file is read on every request, so there is nothing to
restart. Write the new file somewhere private, then install it:

```bash
htpasswd -c -B /root/htpasswd.new ztf          # prompts for the new password
sudo -u $SVC_USER sh -c 'umask 077 && cat > /service/shire/secrets/htpasswd &&
    chmod 600 /service/shire/secrets/htpasswd' < /root/htpasswd.new
rm /root/htpasswd.new
```

(`htpasswd` is in the `httpd-tools` package; `podman exec -it
ztf-alert-archive-web htpasswd -n -B ztf` prints a line you can save instead.)
Check it with `tests/web_test.sh https://ztf.uw.edu ztf:<new password>` and
`ZTF_WEB_TEST_REAL=1`.

## The Slack webhook

`nightly.sh` (in ztf-go-archivist) posts `{"text": "<message>"}` to the URL
in the file. Either kind of Slack webhook works:

- **Incoming webhook** (`https://hooks.slack.com/services/...`): Slack *Apps →
  Incoming Webhooks → Add to Slack*, or an app with the *Incoming Webhooks*
  feature. Nothing else to set up.
- **Workflow Builder trigger** (`https://hooks.slack.com/triggers/...`): a
  workflow that starts *From a webhook*. It must define a text variable named
  exactly `text`, and its *Send a message* step must insert that variable.
  Otherwise the failure text does not reach the channel. The ztf.astro
  deployment uses one of these.

Save the URL as the only line of a file and install it:

```bash
sudo -u $SVC_USER sh -c 'umask 077 && cat > /service/shire/secrets/slack_webhook &&
    chmod 600 /service/shire/secrets/slack_webhook' < /root/slack_webhook
rm /root/slack_webhook
```

It is read each night, so there is nothing to restart. To test it without
waiting for a failure:

```bash
podman exec ztf-alert-archive-archivist sh -c \
    'curl -sS -H "Content-Type: application/json" --data "{\"text\": \"ZTF alert archive: webhook test\"}" "$(cat /run/secrets/slack_webhook)"'
```

Anyone holding the URL can post to that channel. If it leaks, revoke it in
Slack and install a new one.
