#!/bin/sh
# Renders the docs site with dogbed itself: docs/src/*.knap + docs/data/*.json
# -> docs/site/*.html. Requires the dogbed binary (zig build). No site
# generator, no npm, no framework — the docs build stays dumb on purpose.
set -eu
cd "$(dirname "$0")/.."
: "${DOGBED:=zig-out/bin/dogbed}"

# Assets: sources in docs/assets/, copied verbatim into docs/site/assets/
# so the repro gate covers the images too.
mkdir -p docs/site/assets
cp docs/assets/oliver-dogbed.webp docs/assets/oliver-badge.webp docs/site/assets/
cp docs/assets/oliver-og.png docs/assets/oliver-favicon.png docs/site/assets/

for page in index shell templates contract dogfood deploy; do
    case "$page" in
        index)     t="dogbed — a document compiler" ;;
        shell)     t="dogbed — the document shell" ;;
        templates) t="dogbed — starter templates" ;;
        contract)  t="dogbed — the CLI contract" ;;
        dogfood)   t="dogbed — dogfood" ;;
        deploy)    t="dogbed — the publishing pipeline" ;;
    esac
    "$DOGBED" render "docs/src/$page.knap" \
        -d "docs/data/$page.json" \
        --title "$t" --css style.css \
        --head '<link rel="icon" type="image/png" href="assets/oliver-favicon.png">' \
        --head '<meta property="og:title" content="dogbed">' \
        --head '<meta property="og:description" content="the dog builds its own docs">' \
        --head '<meta property="og:image" content="https://dogbed.filed.fyi/assets/oliver-og.png">' \
        > "docs/site/$page.html"
done
echo "rendered: index shell templates contract dogfood deploy"
