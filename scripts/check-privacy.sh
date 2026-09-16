#!/usr/bin/env bash
#
# Asserts grrclone's central promise: it contacts nothing but the storage providers the
# user configured. No telemetry, no analytics, no crash reporting, no runtime downloads.
#
# This runs in CI and is a build failure, not a review convention, because it is cheap to
# assert and easy to regress. Run it locally before pushing:
#
#   scripts/check-privacy.sh
#
set -uo pipefail
cd "$(dirname "$0")/.."

FAILED=0

fail() { printf '\033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }
pass() { printf '\033[32mok\033[0m    %s\n' "$1"; }

# Only real code is scanned. Scanning the workflow or this script would match their own
# patterns, and scanning comments would flag the notes explaining why something is
# avoided — both of which happened on the first attempt.
sources() { git ls-files 'Sources/*.swift' 'App/*.swift'; }

# Strip comments so a note explaining why an API is avoided is not itself a violation.
#
# A naive `s|//.*||` also eats the rest of any URL, because `https://` contains `//`.
# That silently defeats the analytics check: `"https://mixpanel.com/x"` becomes
# `"https:` and the forbidden name disappears before it can be matched. So `//` is
# treated as a comment only when it is not part of a scheme separator.
strip_comments() { sed -e 's|^[[:space:]]*//.*||' -e 's|\([^:]\)//.*|\1|'; }

scan() { # name pattern
    local name="$1" pattern="$2" hits
    hits=$(sources | while read -r f; do
        strip_comments < "$f" | grep -nEi "$pattern" | sed "s|^|$f:|"
    done)
    if [[ -n "$hits" ]]; then
        fail "$name"
        echo "$hits" | sed 's/^/        /'
    else
        pass "$name"
    fi
}

echo "Checking grrclone's privacy guarantees"
echo

# An analytics or crash-reporting dependency would send data somewhere the user did not
# choose, which is the one thing this project promises never to do.
scan "no analytics or crash-reporting SDKs" \
     'sentry|firebase|crashlytics|mixpanel|posthog|segment\.io|google-analytics|bugsnag|datadog'

# --rc-web-gui makes rclone download a bundle from GitHub at runtime.
scan "no rclone web GUI (downloads code at runtime)" \
     'rc-web-gui'

# rclone's NFS and WebDAV servers implement no authentication whatsoever. Binding one to
# anything but loopback publishes the user's entire storage account to the local network.
#
# Allow-list, not deny-list. Enumerating bad forms missed `[::]:0`, a LAN address, and
# anything built by interpolation; the only safe rule is that every bind literal must
# start with a loopback host.
check_binds() {
    local bad
    bad=$(sources | while read -r f; do
        strip_comments < "$f" \
            | grep -nE '"addr"[[:space:]]*:' \
            | grep -vE '\.string\("(localhost|127\.0\.0\.1|\[::1\]):' \
            | sed "s|^|$f:|"
    done)
    if [[ -n "$bad" ]]; then
        fail "servers bind to loopback only"
        echo "$bad" | sed 's/^/        /'
    else
        pass "servers bind to loopback only"
    fi
}
check_binds

# Anything fetched at runtime bypasses the pinned, checksummed rclone we ship.
scan "no runtime downloads of executables" \
     'URLSession.*(download|dataTask).*(github\.com|releases|\.zip|\.dmg)'

echo
if [[ $FAILED -eq 0 ]]; then
    echo "All privacy checks passed."
else
    echo "Privacy checks failed. See CONTRIBUTING.md — this is a hard rule, not a preference."
fi
exit $FAILED
