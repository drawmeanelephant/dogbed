#!/bin/sh
# Renders the docs site with dogbed itself: docs/src/*.knap + docs/data/*.json
# -> docs/site/*.html. Requires the dogbed binary (zig build). No site
# generator, no npm, no framework — the docs build stays dumb on purpose.
set -eu
cd "$(dirname "$0")/.."
: "${DOGBED:=zig-out/bin/dogbed}"

for page in index shell templates contract dogfood; do
    case "$page" in
        index)     t="dogbed — a document compiler" ;;
        shell)     t="dogbed — the document shell" ;;
        templates) t="dogbed — starter templates" ;;
        contract)  t="dogbed — the CLI contract" ;;
        dogfood)   t="dogbed — dogfood" ;;
    esac
    "$DOGBED" render "docs/src/$page.knap" \
        -d "docs/data/$page.json" \
        --title "$t" --css style.css \
        > "docs/site/$page.html"
done
echo "rendered: index shell templates contract dogfood"
