#!/bin/bash
# Run web/conf/httpd.conf under a locally installed Apache (RHEL layout:
# /usr/sbin/httpd, modules in /etc/httpd/modules) against a fixture, and run
# tests/web_test.sh against it. For machines with no container runtime. The
# real check is the container itself; see DEPLOY.md.
#
#   tests/local_httpd_test.sh [PORT [USER:PASSWORD]]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=${1:-18080}
WORK=$(mktemp -d)
cleanup() {
    [ -f "$WORK/httpd.pid" ] && kill "$(cat "$WORK/httpd.pid")" 2>/dev/null || true
    sleep 1
    rm -rf "$WORK"
}
trap cleanup EXIT

# By default a throwaway fixture. To try the configuration against a real
# copy of the archive instead (read-only), set ZTF_TEST_ALERTS_ROOT and
# ZTF_TEST_HTPASSWD and pass the partnership login as the second argument.
ALERTS_ROOT=${ZTF_TEST_ALERTS_ROOT:-$WORK/data/alerts}
HTPASSWD=${ZTF_TEST_HTPASSWD:-$WORK/data/secrets/htpasswd}
if [ -n "${ZTF_TEST_ALERTS_ROOT:-}" ]; then
    export ZTF_WEB_TEST_REAL=1
else
    "$REPO_DIR/tests/make_fixture.sh" "$WORK/data" > /dev/null
fi

cat > "$WORK/httpd.conf" <<CONF
ServerRoot /etc/httpd
PidFile $WORK/httpd.pid
ErrorLog $WORK/error.log
LoadModule mpm_prefork_module modules/mod_mpm_prefork.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule authn_core_module modules/mod_authn_core.so
LoadModule authn_file_module modules/mod_authn_file.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_user_module modules/mod_authz_user.so
LoadModule auth_basic_module modules/mod_auth_basic.so
LoadModule mime_module modules/mod_mime.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule headers_module modules/mod_headers.so
LoadModule autoindex_module modules/mod_autoindex.so
LoadModule dir_module modules/mod_dir.so
LoadModule alias_module modules/mod_alias.so
TypesConfig /etc/mime.types
DirectoryIndex index.html
<Directory />
    AllowOverride None
    Require all denied
</Directory>
Define SERVER_NAME localhost
Define ZTF_LISTEN $PORT
Define ZTF_HTDOCS $REPO_DIR/web/htdocs
Define ZTF_FANCY_INDEX $REPO_DIR/web/fancy-index
Define ZTF_CONF_DIR $REPO_DIR/web/conf
Define ZTF_ALERTS_ROOT $ALERTS_ROOT
Define ZTF_HTPASSWD $HTPASSWD
Include $REPO_DIR/web/conf/httpd.conf
CONF
httpd -f "$WORK/httpd.conf" -t
# Its own session: on shutdown Apache signals its whole process group.
setsid httpd -f "$WORK/httpd.conf" -DFOREGROUND > "$WORK/access.log" 2>&1 &
for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
    sleep 0.5
done

status=0
"$REPO_DIR/tests/web_test.sh" "http://127.0.0.1:$PORT" ${2:+"$2"} || status=$?
if [ "$status" -ne 0 ]; then
    echo "--- error log ---"
    tail -n 20 "$WORK/error.log"
fi
exit $status
