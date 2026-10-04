# dogbed — spec

## What it is

A document compiler. It reads a Knap template plus data (a JSON object, from
a file or stdin), renders the template to Textile with k4o, renders the
Textile to HTML with oliver, and writes the result to stdout. By default
that is a bare HTML fragment; `--title`/`--css` finish it into a document
(see the CLI contract).

```
template.knap + data.json --k4o--> Textile --oliver--> HTML
```

## What it is not

Not a content management system. No editing, no storage, no users, no web
UI, no database, no accounts, no themes marketplace. It is a compiler:
deterministic, pipeable, boring in the good way. If it ever grows an edit
button, kill it.

## Why k4o + oliver, and why one binary

- k4o alone is a Textile emitter nobody asked for. oliver alone renders
  documents but cannot template. Together they are the two halves of
  "I have data, I want a document."
- The Textile middle step is the IR: it keeps the stages composable and
  independently testable instead of fused.
- One static Zig binary, not ten things. Both engines are Zig libraries;
  dogbed embeds them. No pin drift, no subprocesses, no runtime.

## Non-goals

- Markdown input to the pipeline (oliver already does that alone; dogbed
  is about *templated* documents).
- HTML4 Strict output (declined upstream; the bar is a named consumer).
- Any CMS feature, ever (see above).
- Template versioning, remote templates, template discovery paths — the
  starter library is three embedded templates, done.

## The workflow hole it fills

The recurring job: structured findings in, consistent document out.

- PR review verdicts (findings JSON + verdict template → review HTML).
- Audit reports.
- Blog filing: intake data + post template → finished HTML
  (the squirrel.filed.fyi filing flow is the prototype).
- Release notes, changelogs, field notes.

## CLI contract

- `dogbed render <template.knap> [--data <file>] [--profile html|xhtml]
  [--title <text>] [--css <href>] [--head <html>] [--lang <tag>]
  [--max-output <bytes>]`
- `--data -` reads the JSON object from stdin:
  `cat findings.json | dogbed render verdict.knap -d - > verdict.html`
- Output is a bare HTML fragment unless `--title`, `--css`, `--head`, or
  `--lang` is passed. Any of them wraps the fragment in a minimal shell:
  HTML5 normally, XHTML 1.0 Strict under `--profile xhtml`. The title is
  HTML-escaped; the css hrefs, head lines, and lang tag pass through
  verbatim (URL, path, markup, or BCP 47 tag — the consumer's problem, not
  ours). `--lang` lands on the root element: `lang` for HTML5, `lang` plus
  `xml:lang` for XHTML (WCAG 3.1.1). No flags means byte-identical
  fragment output.
- `--max-output` caps the final document in bytes, shell included (it also
  bounds the k4o stage; default 256 MiB, `0` = unlimited). Nested loops
  multiply, so the default is generous but finite.
- `dogbed template <name>` prints an embedded starter template to stdout so
  the user copies it and owns it. The library is exactly three starters
  (verdict, release-notes, reading-note) with matching example data —
  no discovery paths, no versioning, no fetching.
- `dogbed init` scaffolds a site skeleton into the current directory:
  routes.txt (the route table), src/ (one Knap template per route, plus
  layout.knap — the page frame new pages start from), data/ (one JSON
  object per route), assets/, and build.sh, which renders every route with
  the render command above. Poop rules, same as `k4o init`: only create
  files that don't exist — never overwrite an existing file, modified or
  not; a superseded scaffold file is archived to a timestamped dir and the
  location is reported (bagged, not curbed; no trash day). init scaffolds,
  nothing else.
- Errors go to stderr, stdout stays empty, exit 1. A failed render never
  emits a half-rendered document.

## Open questions

- Whether Knap stays the template language long-term or was the bootstrap.
