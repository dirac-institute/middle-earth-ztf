#!/bin/bash
# Compare two alert tarballs for the same night made by two archivers (epyc's
# and the VM's, during the parallel run). They are never byte-identical: tar
# entry timestamps are the time of writing. What must match is the set of
# alerts, which is the set of entry names (<candid>.avro).
#
#   tools/compare_tarballs.sh EPYC.tar.gz VM.tar.gz
#
# Run it where both are visible, e.g. on epyc:
#   tools/compare_tarballs.sh \
#       /epyc/data/ztf/alerts/public/ztf_public_20261201.tar.gz \
#       /astro/store/shire/@Service/ztf/data/alerts/public/ztf_public_20261201.tar.gz
#
# Exits 0 if the two hold the same alerts, 1 if not. Reads both files in
# full, so allow a few minutes for a multi-GB night.

set -euo pipefail

A=${1:?usage: compare_tarballs.sh A.tar.gz B.tar.gz}
B=${2:?usage: compare_tarballs.sh A.tar.gz B.tar.gz}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

nice tar -tzf "$A" | LC_ALL=C sort > "$TMP/a"
nice tar -tzf "$B" | LC_ALL=C sort > "$TMP/b"
uniq "$TMP/a" > "$TMP/ua"
uniq "$TMP/b" > "$TMP/ub"

na=$(wc -l < "$TMP/a")
nb=$(wc -l < "$TMP/b")
ua=$(wc -l < "$TMP/ua")
ub=$(wc -l < "$TMP/ub")
LC_ALL=C comm -23 "$TMP/ua" "$TMP/ub" > "$TMP/only_a"
LC_ALL=C comm -13 "$TMP/ua" "$TMP/ub" > "$TMP/only_b"
only_a=$(wc -l < "$TMP/only_a")
only_b=$(wc -l < "$TMP/only_b")

echo "A: $A"
echo "   $na entries, $ua distinct"
echo "B: $B"
echo "   $nb entries, $ub distinct"
echo "only in A: $only_a    only in B: $only_b"
if [ "$only_a" -eq 0 ] && [ "$only_b" -eq 0 ]; then
    if [ "$na" -ne "$nb" ]; then
        echo "SAME ALERTS, but a different number of entries: one side has duplicates"
    else
        echo "SAME"
    fi
    exit 0
fi
echo "DIFFERENT. First few alerts on one side only:"
head -n 5 "$TMP/only_a" | sed 's/^/  only in A: /'
head -n 5 "$TMP/only_b" | sed 's/^/  only in B: /'
exit 1
