# dogbed

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
dogbed render <template.knap> [--data <data.json>] [--profile html|xhtml] [--max-output <bytes>]
dogbed --help
dogbed --version
```

- `--data, -d <file>` — JSON object with the template variables (default `{}`).
  Use `-` to read from stdin.
- `--profile, -p` — `html` (default) or `xhtml` oliver output profile.
- `--max-output, -m` — ceiling on the k4o render in bytes (`k`/`m`/`g`
  suffixes accepted). Default 256 MiB; `0` means no limit.

On any error the message goes to stderr, stdout stays empty, exit code is 1.

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
