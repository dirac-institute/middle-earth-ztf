#!/bin/bash
# Check the website's behaviour over HTTP.
#
#   tests/web_test.sh BASE_URL [USER:PASSWORD]
#
# Against the fixture from tests/make_fixture.sh (the default credentials are
# its), every check applies. Against the real archive, pass the real
# partnership credentials; checks that name fixture files are skipped when
# ZTF_WEB_TEST_REAL=1.
#
#   tests/web_test.sh http://localhost:8080
#   ZTF_WEB_TEST_REAL=1 tests/web_test.sh https://ztf.uw.edu ztf:<password>

set -uo pipefail

BASE=${1:?usage: web_test.sh BASE_URL [USER:PASSWORD]}
BASE=${BASE%/}
CRED=${2:-ztf:fixture-password}
REAL=${ZTF_WEB_TEST_REAL:-0}

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1 ($2)"; }

# status DESCRIPTION EXPECTED [curl args...] URL-PATH
status() {
    local desc=$1 want=$2
    shift 2
    local got
    got=$(curl -s -o /dev/null -w '%{http_code}' "${@:1:$#-1}" "$BASE${*: -1}")
    if [[ " $want " == *" $got "* ]]; then ok "$desc"; else fail "$desc" "wanted $want, got $got"; fi
}
# body DESCRIPTION PATTERN [curl args...] URL-PATH: the response matches PATTERN
body() {
    local desc=$1 pat=$2
    shift 2
    local out
    out=$(curl -s "${@:1:$#-1}" "$BASE${*: -1}")
    if grep -q -E -- "$pat" <<< "$out"; then ok "$desc"; else fail "$desc" "no match for $pat"; fi
}
nobody() {
    local desc=$1 pat=$2
    shift 2
    local out
    out=$(curl -s "${@:1:$#-1}" "$BASE${*: -1}")
    if grep -q -E -- "$pat" <<< "$out"; then fail "$desc" "matched $pat"; else ok "$desc"; fi
}

echo "# landing page"
status "/ is served" 200 /
body "/ is the ZTF landing page" "Zwicky Transient Facility Alert Archive" /
body "its Data Access button links to the listing" 'href="alerts/public/"' /
status "its stylesheet is served" 200 /css/main.css
status "its background image is served" 200 /images/horsehead-bg.jpg
status "the old PHP mailer is gone" 404 /inc/sendEmail.php

echo "# public listing"
status "/alerts/public/ is open" 200 /alerts/public/
status "/alerts/public (no slash) gives the listing, not a redirect" 200 /alerts/public
body "its links resolve against /alerts/public/" '<base href="/alerts/public/">' /alerts/public
body "it lists tarballs" 'ztf_public_[0-9]{8}\.tar\.gz' /alerts/public/
body "it lists MD5SUMS" 'href="MD5SUMS"' /alerts/public/
body "it has the archive's header text" "What is included" /alerts/public/
body "it has the archive's footer" "A Service of" /alerts/public/
listing=$(curl -s "$BASE/alerts/public/" | grep -o -E 'ztf_public_[0-9]{8}\.tar\.gz' | awk '!seen[$0]++')
if [[ -n $listing && "$listing" == "$(echo "$listing" | sort -r)" ]]; then ok "newest tarball first"; else fail "newest tarball first" "not in descending order"; fi
nobody "it hides the theme directory" 'href="fancy-index/"' /alerts/public/
nobody "it hides VALIDATE" 'href="VALIDATE' /alerts/public/
nobody "it hides dot-files" 'href="\.' /alerts/public/
status "the theme stylesheet is served" 200 /alerts/public/fancy-index/style.css
status "the theme script is served" 200 /alerts/public/fancy-index/script.js
status "the theme logo is served" 200 /alerts/public/fancy-index/logos/ztf-logo.png
svgtype=$(curl -s -o /dev/null -w '%{content_type}' "$BASE/alerts/public/fancy-index/icons/file-zip.svg")
if [[ $svgtype == image/svg+xml* ]]; then ok "icons are served as SVG"; else fail "icons are served as SVG" "$svgtype"; fi
status "MD5SUMS downloads" 200 /alerts/public/MD5SUMS
status ".htaccess is not served" "403 404" /alerts/public/.htaccess
status ".git is not served" "403 404" /alerts/public/.git/HEAD

first=$(echo "$listing" | head -n 1)
status "a tarball is there to download" 200 -I "/alerts/public/$first"
status "a Range request gets 206" 206 -r 0-9 "/alerts/public/$first"
len=$(curl -s -r 0-9 "$BASE/alerts/public/$first" | wc -c)
if [[ $len -eq 10 ]]; then ok "the range is 10 bytes"; else fail "the range is 10 bytes" "got $len"; fi

if [[ $REAL != 1 ]]; then
    echo "# fixture strays"
    body "the theme comes from the image, not the data directory" "font-family|body" /alerts/public/fancy-index/style.css
    nobody "the stale on-disk theme is not served" "stale theme copy" /alerts/public/fancy-index/style.css
    status "an in-progress tarball is not served" "403 404" /alerts/public/.tmp.ztf_public_20261120.tar.gz.123
    status "a set-aside tarball is not served" "403 404" /alerts/public/.ztf_public_20181105.tar.gz.OLD
    status "an editor backup of .htaccess is not served" "403 404" "/alerts/public/.htaccess~"
    got=$(curl -s "$BASE/alerts/public/ztf_public_20261118.tar.gz" | md5sum | cut -d' ' -f1)
    want=$(curl -s "$BASE/alerts/public/MD5SUMS" | awk '$2 == "ztf_public_20261118.tar.gz" { print $1 }')
    if [[ -n $want && $got == "$want" ]]; then ok "a full download matches MD5SUMS"; else fail "a full download matches MD5SUMS" "$got vs $want"; fi
fi

echo "# partnership listing"
status "/alerts/partnership/ needs a password" 401 /alerts/partnership/
realm=$(curl -s -o /dev/null -D - "$BASE/alerts/partnership/" | tr -d '\r' | grep -i '^WWW-Authenticate:')
if [[ $realm == *'Basic realm="Access for ZTF Partnership Members Only"'* ]]; then ok "the realm is unchanged"; else fail "the realm is unchanged" "$realm"; fi
status "a wrong password is refused" 401 -u "ztf:definitely-wrong" /alerts/partnership/
status "MD5SUMS needs a password" 401 /alerts/partnership/MD5SUMS
status "the theme needs a password too" 401 /alerts/partnership/fancy-index/style.css
status "the right password opens the listing" 200 -u "$CRED" /alerts/partnership/
status "/alerts/partnership (no slash) needs a password" 401 /alerts/partnership
body "and gives the listing with it" '<base href="/alerts/partnership/">' -u "$CRED" /alerts/partnership
body "it lists partnership tarballs" 'ztf_partnership_[0-9]{8}\.tar\.gz' -u "$CRED" /alerts/partnership/
body "it uses the partnership theme" "/alerts/partnership/fancy-index/style.css" -u "$CRED" /alerts/partnership/
status "the partnership theme is served" 200 -u "$CRED" /alerts/partnership/fancy-index/style.css
status ".htaccess is not served even with the password" "403 404" -u "$CRED" /alerts/partnership/.htaccess
plist=$(curl -s -u "$CRED" "$BASE/alerts/partnership/" | grep -o -E 'ztf_partnership_[0-9]{8}\.tar\.gz' | head -n 1)
status "a partnership tarball needs a password" 401 -r 0-9 "/alerts/partnership/$plist"
status "a partnership tarball downloads with it" 206 -r 0-9 -u "$CRED" "/alerts/partnership/$plist"

echo "# nothing else"
status "/alerts/ itself is not a listing" "403 404" /alerts/
status "the htpasswd file is not reachable" "403 404" /htpasswd
status "/jupyter is gone" 404 /jupyter/

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
