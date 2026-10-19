# a dogbed site

Scaffolded by `dogbed init` — a document compiler, not a CMS. One route,
one template, one JSON file:

    src/<route>.knap + data/<route>.json  ->  site/<route>.html

## The pieces

- `routes.txt` — the route table: one line per page, `name<TAB>page title`.
- `src/` — one Knap template per route. `src/layout.knap` is the page frame
  new pages start from (knap has no includes, so a page owns its frame).
- `data/` — one JSON object per route. Strings may carry Textile inline:
  *bold*, _italic_, @code@, "label":target.
- `assets/` — static files, copied into `site/` by build.sh.
- `build.sh` — the wiring: renders every route in routes.txt.

## Build

Needs the `dogbed` binary on your PATH (`DOGBED=<path> ./build.sh` to point
at a specific one):

    ./build.sh

Output lands in `site/`. Open `site/index.html` in a browser.

## Add a page

1. `cp src/layout.knap src/<name>.knap` and edit the copy
2. add a line to `routes.txt`: `<name><TAB><Page Title>`
3. write `data/<name>.json` with the fields the template reads

## Run `dogbed init` again any time

init never overwrites: it only fills gaps. An existing file — yours or a
previous scaffold's — is left exactly as it is; if a newer scaffold ever
supersedes one of its own files, the old file is archived (never deleted)
and the archive location is printed.
