#!/bin/sh
# Renders the site: src/<route>.knap + data/<route>.json -> site/<route>.html,
# one route per line in routes.txt (name<TAB>page title). Requires the dogbed
# binary — DOGBED=<path> overrides it (default: dogbed on your PATH).
# Dumb on purpose.
#
# Each page renders to a uniquely named temporary file next to its
# destination and is renamed over it only once the render has succeeded:
# a failed rebuild leaves the last good page untouched.
set -eu
cd "$(dirname "$0")"
: "${DOGBED:=dogbed}"

mkdir -p site
cp assets/style.css site/style.css

# The temp file currently being built. Cleaned up on any way out — an
# ordinary failure, an interrupt, or a term signal.
tmp=""
cleanup() {
    if [ -n "$tmp" ]; then rm -f "$tmp"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tab="$(printf '\t')"
while IFS="$tab" read -r route title; do
    case "$route" in '' | '#'*) continue ;; esac
    tmp="site/.$route.html.$$"
    if "$DOGBED" render "src/$route.knap" -d "data/$route.json" \
        --title "$title" --css style.css > "$tmp"
    then
        mv -f "$tmp" "site/$route.html"
        tmp=""
        echo "rendered: $route"
    else
        status=$?
        rm -f "$tmp"
        tmp=""
        echo "dogbed: render failed for $route (exit $status), leaving site/$route.html untouched" >&2
        exit "$status"
    fi
done < routes.txt
