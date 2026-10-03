#!/bin/sh
# Renders the site: src/<route>.knap + data/<route>.json -> site/<route>.html,
# one route per line in routes.txt (name<TAB>page title). Requires the dogbed
# binary — DOGBED=<path> overrides it (default: dogbed on your PATH).
# Dumb on purpose.
set -eu
cd "$(dirname "$0")"
: "${DOGBED:=dogbed}"

mkdir -p site
cp assets/style.css site/style.css

tab="$(printf '\t')"
while IFS="$tab" read -r route title; do
    case "$route" in '' | '#'*) continue ;; esac
    "$DOGBED" render "src/$route.knap" -d "data/$route.json" \
        --title "$title" --css style.css > "site/$route.html"
    echo "rendered: $route"
done < routes.txt
