# dogbed

<p align="center">
  <img src="docs/assets/oliver-og.png" alt="The dogbed social card: oliver — a cartoon Weimaraner in an orange HTML5 cape, with the words 'dogbed: the dog builds its own docs'." width="640">
</p>

A document compiler, not a CMS. Knap templates in, HTML documents out.

```
cat findings.json | dogbed render report.knap -d - > report.html
```

**The pipeline:** a [Knap](https://github.com/drawmeanelephant/k4o) template plus a
JSON object renders to Textile via [k4o](https://github.com/drawmeanelephant/k4o),
which [oliver](https://github.com/drawmeanelephant/oliver) then renders to HTML.
One static binary, no runtime, no JavaScript, no database, no edit button.

## Usage

```
dogbed render <template.knap> [--data <data.json>] [--profile html|xhtml]
              [--title <text>] [--css <href>] [--head <html>] [--lang <tag>]
              [--max-output <bytes>]
dogbed template <name>
dogbed init
dogbed --help
dogbed --version
```

- `--data, -d <file>` — JSON object with the template variables (default `{}`).
  Use `-` to read from stdin.
- `--profile, -p` — `html` (default) or `xhtml` oliver output profile.
- `--title <text>` — wrap the output in a minimal HTML5 shell and set
  `<title>` (HTML-escaped). With `--profile xhtml` the shell is XHTML 1.0
  Strict instead.
- `--css <href>` — add `<link rel="stylesheet" href="…">` to the shell.
  Repeatable; links keep flag order. The href is emitted verbatim — URL or
  relative path, unvalidated.
- `--head <html>` — splice one verbatim line into the shell's `<head>`
  (meta tags, favicon links). Repeatable, order kept, unvalidated.
- `--lang <tag>` — set the document language on the shell's root element
  (`<html lang="…">`; XHTML also gets `xml:lang`). Emitted verbatim —
  pick a valid BCP 47 tag (`en`, `pt-BR`).
- `--max-output, -m` — ceiling on the emitted document in bytes, shell
  included (`k`/`m`/`g` suffixes accepted). Default 256 MiB; `0` means no
  limit. Enforced while the document renders: every stage stops the moment
  a write would cross the cap, so over-limit output is never materialized.
  An emitted-byte ceiling is not a memory or CPU sandbox — embedders still
  need timeouts, concurrency limits, and OS-level resource controls.

**Fragment vs document:** by default `render` emits a bare HTML fragment
(`<h1>…</h1><p>…</p>`), ready to pipe into something bigger. Passing any
shell flag (`--title`, `--css`, `--head`, `--lang`) finishes the job
instead: the same fragment wrapped in a minimal HTML shell, nothing more.

On any error the message goes to stderr, stdout stays empty, exit code is 1.

## Starter templates

Three starters ship inside the binary — no fetching, no discovery paths.
`dogbed template <name>` prints one to stdout so you copy it and own it;
`dogbed template --list` shows the names. Each has matching example data in
[share/](share/):

- `verdict` — PR review verdict: blockers, nits, summary.
- `release-notes` — highlights, breaking changes, added/changed/fixed;
  empty sections disappear.
- `reading-note` — author, rating, quote, notes.

```
dogbed template verdict > my-verdict.knap
cat findings.json | dogbed render my-verdict.knap -d - --title "Review" > review.html
```

## Scaffolding a site

`dogbed init` fills the current directory with a working skeleton:
`routes.txt` (the route table), `src/` (one Knap template per route, plus
`layout.knap` — the page frame new pages start from), `data/` (one JSON
object per route), `assets/`, `build.sh`, and a README. The shape mirrors
[this site's own docs build](docs/build.sh): one template plus one JSON file
per route, wired by a dumb shell script.

init is strictly additive: an existing file is never overwritten, modified
or not — run it again any time, it only fills gaps. When a newer scaffold
supersedes one of its own files, the old file is archived to a timestamped
dir and the location is printed; nothing is ever deleted.

```
mkdir my-site && cd my-site
dogbed init
./build.sh          # renders routes.txt -> site/ (needs dogbed on PATH)
```

## Building

Zig 0.16.0. `zig build` produces `zig-out/bin/dogbed`; `zig build test`
runs the suite.

## Why this exists

Every week is the same dance: structured findings in, a consistent
good-looking document out — PR verdicts, audit reports, release notes.
oliver renders documents but can't template; k4o templates but only emits
Textile. dogbed is the two halves joined: data → finished document.
See [SPEC.md](SPEC.md).

## License

MIT — see [LICENSE](LICENSE).
