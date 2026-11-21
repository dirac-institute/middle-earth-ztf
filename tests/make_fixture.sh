#!/bin/bash
# Build a small fake data directory with the same layout as /service/shire,
# for testing the website without the real archive.
#
#   tests/make_fixture.sh DIR
#
# Creates DIR/alerts/{public,partnership} with a few small tarballs and the
# kinds of stray files the real directories contain, DIR/secrets/htpasswd
# (user "ztf", password "fixture-password"), DIR/scratch and DIR/logs.

set -euo pipefail

DIR=${1:?usage: make_fixture.sh DIR}
mkdir -p "$DIR"/alerts/public "$DIR"/alerts/partnership "$DIR"/secrets "$DIR"/scratch "$DIR"/logs

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
for program in public partnership; do
    d="$DIR/alerts/$program"
    : > "$d/MD5SUMS"
    for date in 20261117 20261118 20261119; do
        echo "fake alert for $program $date" > "$TMP/1.avro"
        # Pad one file past a megabyte so Range requests have something to cut.
        if [ "$date" = 20261118 ]; then
            head -c 1500000 /dev/urandom > "$TMP/2.avro"
        else
            echo "second alert" > "$TMP/2.avro"
        fi
        tar -czf "$d/ztf_${program}_${date}.tar.gz" -C "$TMP" 1.avro 2.avro
        (cd "$d" && md5sum "ztf_${program}_${date}.tar.gz" >> MD5SUMS)
    done
    # Strays, as found in the real directories. None should be listed, and
    # the dot-files must not be downloadable.
    echo "Require all denied" > "$d/.htaccess"
    echo "old" > "$d/.htaccess~"
    echo "partial" > "$d/.tmp.ztf_${program}_20261120.tar.gz.123"
    echo "set aside" > "$d/.ztf_${program}_20181105.tar.gz.OLD"
    echo "#!/bin/sh" > "$d/VALIDATE"
    echo "ok" > "$d/VALIDATE.out"
    mkdir -p "$d/.git" "$d/fancy-index"
    echo "ref: refs/heads/master" > "$d/.git/HEAD"
    echo "stale theme copy on disk" > "$d/fancy-index/style.css"
done

# user ztf / password fixture-password
printf 'ztf:%s\n' "$(openssl passwd -apr1 fixture-password)" > "$DIR/secrets/htpasswd"
chmod 600 "$DIR/secrets/htpasswd"
echo "fixture written to $DIR"
