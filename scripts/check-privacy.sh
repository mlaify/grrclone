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
# Tracked files *and* new ones not yet committed.
#
# This used to be `git ls-files` alone, which silently skipped any file that had not
# been committed yet. A new source file containing telemetry passed the check until
# the moment it was committed — and the moment you most want this check to be honest
# is while you are writing that file. Found when the update checker, still untracked,
# sailed through a run that should have examined it.
#
# --exclude-standard keeps .gitignore honoured, so build output is still skipped.
sources() {
    git ls-files --cached --others --exclude-standard 'Sources/*.swift' 'App/*.swift'
}

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

# Anything fetched at runtime bypasses the pinned, checksummed rclone we ship — and
# an app that can download and run code is a different kind of program from one that
# cannot.
#
# Widened from the original rule, which named only `download` and `dataTask`. The
# update checker uses `data(for:)`, which that pattern did not cover: it passed the
# check by using an API the check had not heard of. Match the artefact rather than
# the call, so a new URLSession method cannot slip past.
scan "no runtime downloads of executables or archives" \
     '\.(dmg|zip|pkg|tar\.gz|tgz)"' 

# The update check is the only outbound connection that is not to the user's own
# storage, and it exists because the user asked for it. Two things must stay true.
#
# It must be off unless enabled. UserDefaults.bool is false when unset, so the danger
# is a registered default quietly turning it on for everyone.
scan "update checks are not enabled by default" \
     'register\(defaults.*UpdateChecksEnabled|UpdateChecksEnabled"?[[:space:]]*:[[:space:]]*true'

# And it must talk to GitHub's API and nowhere else. A second host appearing here is
# how "one opt-in check" becomes telemetry.
check_update_host() {
    local hosts
    hosts=$(sources | while read -r f; do
        strip_comments < "$f" | grep -oE 'https://[a-zA-Z0-9.-]+' | sed 's|https://||'
    done | sort -u | grep -v '^api\.github\.com$' | grep -v '^github\.com$' \
         | grep -v '^rclone\.org$' | grep -v '^claude\.com$' || true)
    if [[ -n "$hosts" ]]; then
        fail "no outbound hosts beyond the update check"
        echo "$hosts" | sed 's/^/        /'
    else
        pass "no outbound hosts beyond the update check"
    fi
}
check_update_host

# App Transport Security must stay at its defaults.
#
# With no NSAppTransportSecurity key, macOS requires TLS 1.2 or better and refuses
# cleartext outright — which is most of the answer to "can the update check be
# intercepted". An exception added later would remove that protection silently, since
# nothing else in the build would change and every test would still pass.
# Named explicitly rather than globbed. The first version of this scanned
# `App/*.plist`, which matches nothing — the file is App/grrclone/Resources/Info.plist
# — so it examined only project.yml and reported ok regardless of what the real plist
# said. It survived an injection test because the injection went into project.yml,
# the path that did work. Testing one input of a check is not testing the check.
#
# Missing files fail rather than pass: a check that cannot find what it audits knows
# nothing, and "nothing" must not read as "fine".
ATS_FILES=(App/project.yml App/grrclone/Resources/Info.plist)

check_ats() {
    local missing=() hits
    for f in "${ATS_FILES[@]}"; do
        [[ -f "$f" ]] || missing+=("$f")
    done
    if (( ${#missing[@]} )); then
        fail "App Transport Security is not weakened"
        printf '        cannot audit, file missing: %s\n' "${missing[@]}"
        return
    fi

    hits=$(grep -n 'NSAllowsArbitraryLoads\|NSExceptionAllowsInsecureHTTPLoads\|NSExceptionMinimumTLSVersion\|NSAppTransportSecurity' \
             "${ATS_FILES[@]}" || true)
    if [[ -n "$hits" ]]; then
        fail "App Transport Security is not weakened"
        echo "$hits" | sed 's/^/        /'
    else
        pass "App Transport Security is not weakened"
    fi
}
check_ats

echo
if [[ $FAILED -eq 0 ]]; then
    echo "All privacy checks passed."
else
    echo "Privacy checks failed. See CONTRIBUTING.md — this is a hard rule, not a preference."
fi
exit $FAILED
