# dogbed — spec

## What it is

A document compiler. It reads a Knap template plus data (a JSON object, from
a file or stdin), renders the template to Textile with k4o, renders the
Textile to HTML with oliver, and writes the finished document to stdout.

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

## The workflow hole it fills

The recurring job: structured findings in, consistent document out.

- PR review verdicts (findings JSON + verdict template → review HTML).
- Audit reports.
- Blog filing: intake data + post template → finished HTML
  (the squirrel.filed.fyi filing flow is the prototype).
- Release notes, changelogs, field notes.

## CLI contract

- `dogbed render <template.knap> [--data <file>] [--profile html|xhtml]
  [--max-output <bytes>]`
- `--data -` reads the JSON object from stdin:
  `cat findings.json | dogbed render verdict.knap -d - > verdict.html`
- Errors go to stderr, stdout stays empty, exit 1. A failed render never
  emits a half-rendered document.
- `--max-output` caps the k4o stage (default 256 MiB, `0` = unlimited);
  nested loops multiply, so the default is generous but finite.

## Open questions

- Whether Knap stays the template language long-term or was the bootstrap.
- Whether the filing workflow wants a small template library shipped
  alongside the binary (verdict.knap, release-notes.knap, ...).
