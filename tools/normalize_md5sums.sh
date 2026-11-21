#!/bin/bash
# Rewrite an MD5SUMS file so that it has one line per tarball, with a bare
# filename, sorted by filename. Run once per program directory at cutover.
#
#   tools/normalize_md5sums.sh /service/shire/alerts/public/MD5SUMS
#
# Until 2020 the archiver wrote bare filenames; after that it wrote
# /epyc/data/ztf/alerts/<program>/<file>, which made `md5sum -c` useless
# anywhere else. Reruns appended a second line for the same file. This strips
# any directory from each line, keeps the last line for each filename, and
# sorts. It computes no checksums: tarballs that never had a line still have
# none. The original is kept next to it as MD5SUMS.pre-normalize.

set -euo pipefail

FILE=${1:?usage: normalize_md5sums.sh PATH/TO/MD5SUMS}
[ -f "$FILE" ] || { echo "$FILE: no such file" >&2; exit 1; }
DIR=$(dirname "$FILE")
TMP="$DIR/.tmp.MD5SUMS.normalize.$$"
trap 'rm -f "$TMP"' EXIT

# Lines are "<md5>  <path>". Later lines win. Anything that is not a
# 32-hex-digit checksum followed by a name is reported and dropped.
awk '
    length($1) != 32 || $1 !~ /^[0-9a-f]+$/ || NF < 2 {
        print "dropping malformed line " NR ": " $0 > "/dev/stderr"
        next
    }
    { name = $2; sub(/.*\//, "", name); sum[name] = $1 }
    END { for (name in sum) print sum[name] "  " name }
' "$FILE" | LC_ALL=C sort -k2 > "$TMP"

before=$(wc -l < "$FILE")
after=$(wc -l < "$TMP")
command cp -p "$FILE" "$DIR/MD5SUMS.pre-normalize"
chmod 664 "$TMP"
mv -f "$TMP" "$FILE"
echo "$FILE: $before lines -> $after lines (original kept as MD5SUMS.pre-normalize)"
