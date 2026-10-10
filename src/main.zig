//! dogbed CLI — a document compiler, not a CMS.
//!
//!     dogbed render <template.knap> [--data <data.json>] [--profile html|xhtml] [--max-output <bytes>]
//!     dogbed template <name>
//!     dogbed init
//!     dogbed --help
//!     dogbed --version
//!
//! Pipeline: Knap template + JSON data --k4o--> Textile --oliver--> HTML.
//! By default the output is a bare HTML fragment; --title or --css wraps it
//! in a minimal document shell. init scaffolds a site skeleton (routes,
//! layout, content dirs, wiring) into the current directory — strictly
//! additive: it never overwrites an existing file, and a superseded scaffold
//! file is archived to a timestamped dir with the location reported.
//!
//! Exit codes: 0 = success, 1 = any error. On error the message goes to
//! stderr and stdout stays empty — rendering is buffered, so partially
//! rendered output is never emitted. --max-output is enforced as bytes are
//! written: the HTML stage and the document shell abort at the cap instead
//! of materializing an oversized document first. An emitted-byte ceiling is
//! not a memory or CPU sandbox — embedders still need timeouts, concurrency
//! limits, and OS-level resource controls.

const std = @import("std");
const kt = @import("k4o");
const oliver = @import("oliver");
const templates = @import("templates");
const scaffold = @import("scaffold");
const build_options = @import("build_options");

const max_input = 16 * 1024 * 1024;

const usage_text =
    \\dogbed — a document compiler. Knap templates in, HTML documents out.
    \\
    \\Usage:
    \\  dogbed render <template.knap> [--data <data.json>] [--profile html|xhtml]
    \\  dogbed template <name>
    \\  dogbed init
    \\  dogbed --help
    \\  dogbed --version
    \\
    \\Commands:
    \\  render              Render a Knap template (with JSON data) to HTML.
    \\  template <name>     Print an embedded starter template to stdout, so
    \\                      you copy it and own it. `dogbed template --list`
    \\                      shows the names: verdict, release-notes,
    \\                      reading-note.
    \\  init                Scaffold a working site skeleton into the
    \\                      current directory: routes.txt, src/ (one Knap
    \\                      template per route plus layout.knap, the page
    \\                      frame), data/, assets/, build.sh, README.md.
    \\                      Strictly additive: an existing file is never
    \\                      overwritten, modified or not; when a scaffold
    \\                      entry supersedes an older one, the old file is
    \\                      archived to a timestamped dir and the location
    \\                      is reported. Bagged, not curbed — no trash day.
    \\
    \\Render options:
    \\  --data, -d <file>   JSON object with the template variables
    \\                      (optional; defaults to {}). Use - for stdin,
    \\                      so: cat data.json | dogbed render -t t.knap -d -
    \\                      The --data=<file> form is also accepted.
    \\  --profile, -p <p>   oliver output profile: html (default) or xhtml.
    \\  --title <text>      Wrap the fragment in a minimal HTML document
    \\                      shell and set <title> (HTML-escaped). With
    \\                      xhtml, the shell is XHTML 1.0 Strict.
    \\  --css <href>        Add <link rel="stylesheet" href="..."> to the
    \\                      shell. Repeatable; links keep flag order. The
    \\                      href passes through verbatim (unvalidated).
    \\                      Any of --title, --css, --head, --lang switches
    \\                      output from a bare fragment to a full document.
    \\  --head <html>       Splice one verbatim line into the shell's
    \\                      <head> (meta tags, favicon links). Repeatable,
    \\                      kept in order; the markup passes through
    \\                      unvalidated — escape your own attributes.
    \\  --lang <tag>        Set the document language on the shell's root
    \\                      element — <html lang="…"> for HTML5, plus
    \\                      xml:lang for XHTML (WCAG 3.1.1). The tag passes
    \\                      through verbatim, so pick a valid BCP 47 tag
    \\                      (en, pt-BR). Like --head, --lang alone switches
    \\                      the output to a full document. The --lang=<tag>
    \\                      form is also accepted.
    \\  --max-output, -m <bytes>
    \\                      Ceiling on the emitted document in bytes, shell
    \\                      included (it also bounds the intermediate Textile
    \\                      render). Nested loops multiply, so a small
    \\                      template over modest data can ask for far more
    \\                      than you expect. Default 268435456 (256 MiB);
    \\                      0 means no limit. The cap trips the moment a
    \\                      write would cross it, so over-limit output is
    \\                      never materialized. An emitted-byte ceiling is
    \\                      not a memory or CPU sandbox: embedders still
    \\                      need timeouts, concurrency limits, and
    \\                      OS-level resource controls.
    \\  --help, -h          Show this help.
    \\  --version, -v       Show the version.
    \\
    \\Exit codes: 0 = success, 1 = any error (message on stderr).
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(init.gpa);
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next(); // program name
    while (it.next()) |arg| try args.append(init.gpa, arg);

    if (args.items.len == 0) return usage(init, "missing command");
    const first = args.items[0];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        return printStdout(init, usage_text);
    }
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "dogbed {s}\n", .{build_options.version});
        return printStdout(init, text);
    }
    if (!std.mem.eql(u8, first, "render")) {
        if (std.mem.eql(u8, first, "template")) return templateCmd(init, args.items[1..]);
        if (std.mem.eql(u8, first, "init")) return initCmd(init, args.items[1..]);
        return usage(init, "unknown command");
    }
    if (args.items.len == 1) return usage(init, "missing template file");

    var template_path: ?[]const u8 = null;
    var data_path: ?[]const u8 = null;
    var profile: oliver.OutputProfile = .html;
    var max_output: usize = kt.default_max_output;
    var title: ?[]const u8 = null;
    var css = std.ArrayList([]const u8).empty;
    defer css.deinit(init.gpa);
    var head = std.ArrayList([]const u8).empty;
    defer head.deinit(init.gpa);
    var lang: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return printStdout(init, usage_text);
        } else if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --template");
            if (template_path != null) return usage(init, "duplicate --template");
            template_path = args.items[i];
        } else if (std.mem.eql(u8, arg, "--data") or std.mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --data");
            if (data_path != null) return usage(init, "duplicate --data");
            data_path = args.items[i];
        } else if (std.mem.startsWith(u8, arg, "--data=") or std.mem.startsWith(u8, arg, "-d=")) {
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --data");
            if (data_path != null) return usage(init, "duplicate --data");
            data_path = value;
        } else if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --profile");
            profile = parseProfile(args.items[i]) orelse return usage(init, "invalid value for --profile (expected html or xhtml)");
        } else if (std.mem.startsWith(u8, arg, "--profile=") or std.mem.startsWith(u8, arg, "-p=")) {
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --profile");
            profile = parseProfile(value) orelse return usage(init, "invalid value for --profile (expected html or xhtml)");
        } else if (std.mem.eql(u8, arg, "--max-output") or std.mem.eql(u8, arg, "-m")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --max-output");
            max_output = parseSize(args.items[i]) catch return usage(init, "invalid value for --max-output");
        } else if (std.mem.startsWith(u8, arg, "--max-output=") or std.mem.startsWith(u8, arg, "-m=")) {
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --max-output");
            max_output = parseSize(value) catch return usage(init, "invalid value for --max-output");
        } else if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --title");
            if (title != null) return usage(init, "duplicate --title");
            if (args.items[i].len == 0) return usage(init, "missing value for --title");
            title = args.items[i];
        } else if (std.mem.startsWith(u8, arg, "--title=")) {
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --title");
            if (title != null) return usage(init, "duplicate --title");
            title = value;
        } else if (std.mem.eql(u8, arg, "--css")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --css");
            if (args.items[i].len == 0) return usage(init, "missing value for --css");
            try css.append(init.gpa, args.items[i]);
        } else if (std.mem.startsWith(u8, arg, "--css=")) {
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --css");
            try css.append(init.gpa, value);
        } else if (std.mem.eql(u8, arg, "--head")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --head");
            if (args.items[i].len == 0) return usage(init, "missing value for --head");
            try head.append(init.gpa, args.items[i]);
        } else if (std.mem.startsWith(u8, arg, "--head=")) {
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --head");
            try head.append(init.gpa, value);
        } else if (std.mem.eql(u8, arg, "--lang")) {
            i += 1;
            if (i >= args.items.len) return usage(init, "missing value for --lang");
            if (lang != null) return usage(init, "duplicate --lang");
            if (args.items[i].len == 0) return usage(init, "missing value for --lang");
            lang = args.items[i];
        } else if (std.mem.startsWith(u8, arg, "--lang=")) {
            const value = arg[std.mem.indexOfScalar(u8, arg, '=').? + 1 ..];
            if (value.len == 0) return usage(init, "missing value for --lang");
            if (lang != null) return usage(init, "duplicate --lang");
            lang = value;
        } else if (arg.len > 1 and arg[0] == '-') {
            return usage(init, "unknown option");
        } else {
            if (template_path != null) return usage(init, "multiple template files (did you mean --data <file>?)");
            template_path = arg;
        }
    }
    const tpl_path = template_path orelse return usage(init, "missing template file");

    const template = std.Io.Dir.readFileAlloc(.cwd(), init.io, tpl_path, arena, .limited(max_input)) catch |e| {
        report("{s} '{s}': {s}", .{ "cannot read template file", tpl_path, @errorName(e) });
        return 1;
    };

    var root: std.json.Value = .{ .object = .empty };
    if (data_path) |dp| {
        const bytes = if (std.mem.eql(u8, dp, "-"))
            readStdin(init, arena) catch |e| {
                report("cannot read stdin: {s}", .{@errorName(e)});
                return 1;
            }
        else
            std.Io.Dir.readFileAlloc(.cwd(), init.io, dp, arena, .limited(max_input)) catch |e| {
                report("{s} '{s}': {s}", .{ "cannot read data file", dp, @errorName(e) });
                return 1;
            };
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch |e| {
            report("invalid JSON in data ({s}): {s}", .{ dp, @errorName(e) });
            return 1;
        };
        switch (parsed) {
            .object => root = parsed,
            else => {
                report("data ({s}) must contain a JSON object", .{dp});
                return 1;
            },
        }
    }

    // Stage 1: Knap template + data --k4o--> Textile.
    var d = kt.Diagnostic{};
    const textile = kt.renderWithLimit(arena, template, root, &d, max_output) catch |e| switch (e) {
        error.Template => {
            report("template: {s}", .{if (d.message.len > 0) d.message else "template error"});
            return 1;
        },
        error.OutOfMemory => {
            report("out of memory", .{});
            return 1;
        },
    };

    // Stage 2: Textile --oliver--> HTML. The document borrows the textile
    // bytes, which live in the arena and outlive the parse result.
    var result = oliver.parse(arena, textile, .textile, .{}) catch |e| {
        report("textile: {s}", .{@errorName(e)});
        return 1;
    };
    defer result.deinit();

    // Stage 2: Textile --oliver--> HTML, into a bounded buffer: the write
    // that would cross --max-output aborts here, so an oversized fragment is
    // never materialized. A cap trip and an allocation failure both surface
    // as error.WriteFailed; `exceeded` tells them apart.
    var html_out = Bounded.init(arena, max_output);
    oliver.html.render(arena, &html_out.writer, &result.document, .{ .profile = profile }) catch |e| {
        if (html_out.exceeded) {
            report("output exceeds --max-output ({d})", .{max_output});
        } else {
            report("render: {s}", .{@errorName(e)});
        }
        return 1;
    };

    // Optional document shell: --title/--css/--head/--lang wrap the
    // fragment; without any of them the fragment is emitted byte-identical
    // to a bare oliver render. The shell stage is bounded by the same cap.
    var final: []const u8 = html_out.written();
    if (title != null or css.items.len > 0 or head.items.len > 0 or lang != null) {
        final = wrapDocument(arena, final, title, css.items, head.items, lang, profile, max_output) catch |e| switch (e) {
            error.OutputLimitExceeded => {
                report("output exceeds --max-output ({d})", .{max_output});
                return 1;
            },
            // Writer errors on an allocating buffer are allocation failures.
            error.WriteFailed => {
                report("out of memory", .{});
                return 1;
            },
        };
    }

    // Both output stages enforce the cap as they write, so `final` is within
    // it (or the cap is 0 = unlimited) — nothing left to check. Buffered
    // render complete: emit in one write so that an error never produces
    // half-rendered output.
    var out_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    w.interface.writeAll(final) catch return stdoutErr(&w);
    w.flush() catch return stdoutErr(&w);
    return 0;
}

fn initCmd(init: std.process.Init, rest: []const []const u8) !u8 {
    const arena = init.arena.allocator();

    for (rest) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return printStdout(init, usage_text);
        }
        return usage(init, "init takes no arguments (it scaffolds the current directory)");
    }

    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    var err_buf: [4096]u8 = undefined;
    var ew = std.Io.File.stderr().writerStreaming(init.io, &err_buf);
    scaffoldSite(.cwd(), init.io, arena, &w.interface, &ew.interface, &scaffold.dirs, &scaffold.files) catch |e| {
        // Flush whatever progress lines were already printed.
        w.flush() catch {};
        ew.flush() catch {};
        if (w.err != null) return stdoutErr(&w);
        if (e == error.OutOfMemory) report("out of memory", .{});
        return 1;
    };
    w.flush() catch return stdoutErr(&w);
    return 0;
}

/// Reports an init failure on `err` and yields error.ScaffoldFailed.
fn failInit(err: *std.Io.Writer, comptime fmt: []const u8, args: anytype) error{ ScaffoldFailed, OutOfMemory } {
    err.print("dogbed: init: " ++ fmt ++ "\n", args) catch {};
    return error.ScaffoldFailed;
}

/// The `dogbed init` worker: scaffolds `scaffold_dirs`/`scaffold_files` into
/// `dir` (the current directory), one report line per action on `out`, error
/// messages on `err`.
///
/// The poop rules: only create files that don't exist — existence is the
/// only test, so an existing file is kept byte-identical whether it is the
/// user's or an older scaffold's. The one exception is a `supersedes` entry
/// (a newer scaffold replacing its own old file): the existing bytes are
/// compared against the old scaffold's content — a match is bagged into
/// `.dogbed-archive/<timestamp>/` (location reported, never deleted) before
/// the new content is written; anything else is user work and is kept.
/// A directory squatting on a needed path fails loudly instead of guessing.
pub fn scaffoldSite(
    dir: std.Io.Dir,
    io: std.Io,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    scaffold_dirs: []const []const u8,
    scaffold_files: []const scaffold.File,
) error{ ScaffoldFailed, OutOfMemory }!void {
    var created_dirs: usize = 0;
    var created: usize = 0;
    var kept: usize = 0;
    var archived: usize = 0;

    for (scaffold_dirs) |d| {
        const status = dir.createDirPathStatus(io, d, .default_dir) catch |e| {
            return failInit(err, "cannot create directory '{s}': {s}", .{ d, @errorName(e) });
        };
        if (status == .created) {
            created_dirs += 1;
            out.print("created  {s}/\n", .{d}) catch return error.ScaffoldFailed;
        }
    }

    for (scaffold_files) |f| {
        if (try tryCreateAndWrite(dir, io, f, out, err)) {
            created += 1;
            continue;
        }
        // Something exists at the path.
        const st = dir.statFile(io, f.path, .{}) catch |e| {
            return failInit(err, "cannot stat '{s}': {s}", .{ f.path, @errorName(e) });
        };
        if (st.kind == .directory) {
            return failInit(err, "'{s}' exists as a directory — move it aside; init scaffolds files, it doesn't scaffold into them", .{f.path});
        }
        if (f.supersedes) |old| {
            const bytes = dir.readFileAlloc(io, f.path, arena, .limited(max_input)) catch |e| {
                return failInit(err, "cannot read '{s}' to check for a superseded scaffold file: {s}", .{ f.path, @errorName(e) });
            };
            if (std.mem.eql(u8, bytes, f.content)) {
                // Already the current scaffold's file — a plain keep, not a
                // supersede candidate.
                kept += 1;
                out.print("kept     {s} (exists — init never overwrites)\n", .{f.path}) catch return error.ScaffoldFailed;
                continue;
            }
            if (!std.mem.eql(u8, bytes, old)) {
                kept += 1;
                out.print("kept     {s} (modified since it was scaffolded — init never overwrites, not even on supersede)\n", .{f.path}) catch return error.ScaffoldFailed;
                continue;
            }
            // It is the old scaffold's own file: bag it, then write the new.
            const archive_prefix = try ensureArchiveDir(dir, io, arena, out, err);
            const archived_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ archive_prefix, basenameOf(f.path) });
            dir.rename(f.path, dir, archived_path, io) catch |e| {
                return failInit(err, "cannot archive '{s}' to '{s}': {s}", .{ f.path, archived_path, @errorName(e) });
            };
            archived += 1;
            out.print("archived {s} -> {s}\n", .{ f.path, archived_path }) catch return error.ScaffoldFailed;
            if (!try tryCreateAndWrite(dir, io, f, out, err)) {
                // Unreachable in practice: the path was just renamed away.
                return failInit(err, "'{s}' reappeared mid-supersede", .{f.path});
            }
            continue;
        }
        kept += 1;
        out.print("kept     {s} (exists — init never overwrites)\n", .{f.path}) catch return error.ScaffoldFailed;
    }

    if (created + archived == 0) {
        out.print("init: {d} kept, nothing created — the scaffold is already complete, nothing touched\n", .{kept}) catch return error.ScaffoldFailed;
    } else {
        out.print("init: {d} created ({d} dirs, {d} files), {d} kept, {d} superseded — next: ./build.sh (DOGBED=<path> picks the binary)\n", .{ created_dirs + created, created_dirs, created, kept, archived }) catch return error.ScaffoldFailed;
    }
}

/// Exclusive-creates and writes one scaffold file. Returns false when
/// something already exists at the path (the caller decides: keep or
/// supersede). Any other failure is reported and returned as ScaffoldFailed.
fn tryCreateAndWrite(dir: std.Io.Dir, io: std.Io, f: scaffold.File, out: *std.Io.Writer, err: *std.Io.Writer) error{ ScaffoldFailed, OutOfMemory }!bool {
    const perms: std.Io.File.Permissions = if (f.executable) .executable_file else .default_file;
    var file = dir.createFile(io, f.path, .{ .exclusive = true, .permissions = perms }) catch |e| switch (e) {
        error.PathAlreadyExists => return false,
        else => return failInit(err, "cannot create '{s}': {s}", .{ f.path, @errorName(e) }),
    };
    file.writeStreamingAll(io, f.content) catch |e| {
        file.close(io);
        return failInit(err, "cannot write '{s}': {s}", .{ f.path, @errorName(e) });
    };
    file.close(io);
    out.print("created  {s}\n", .{f.path}) catch return error.ScaffoldFailed;
    return true;
}

/// Creates `.dogbed-archive/<unix-time>/` (with a `-N` suffix if the same
/// second already has one) and returns its path. Archives are never cleaned:
/// no trash day, no auto-expiry.
fn ensureArchiveDir(dir: std.Io.Dir, io: std.Io, arena: std.mem.Allocator, out: *std.Io.Writer, err: *std.Io.Writer) error{ ScaffoldFailed, OutOfMemory }![]const u8 {
    const ts = std.Io.Timestamp.now(io, .real).toSeconds();
    var n: usize = 0;
    while (n < 1000) : (n += 1) {
        const sub = if (n == 0)
            try std.fmt.allocPrint(arena, "{s}/{d}", .{ scaffold.archive_dirname, ts })
        else
            try std.fmt.allocPrint(arena, "{s}/{d}-{d}", .{ scaffold.archive_dirname, ts, n });
        const status = dir.createDirPathStatus(io, sub, .default_dir) catch |e| {
            return failInit(err, "cannot create archive dir '{s}': {s}", .{ sub, @errorName(e) });
        };
        if (status == .created) {
            out.print("archived -> {s}/ (superseded scaffold files live here now; nothing ever expires)\n", .{sub}) catch return error.ScaffoldFailed;
            return sub;
        }
    }
    return failInit(err, "no free archive dir name for timestamp {d}", .{ts});
}

fn basenameOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

fn templateCmd(init: std.process.Init, rest: []const []const u8) !u8 {
    const arena = init.arena.allocator();

    if (rest.len == 0) return listTemplates(init);
    if (rest.len > 1) return usage(init, "expected one template name (try `dogbed template --list`)");
    const name = rest[0];
    if (std.mem.eql(u8, name, "--list") or std.mem.eql(u8, name, "list")) return listTemplates(init);
    if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
        return printStdout(init, usage_text);
    }
    for (templates.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return printStdout(init, entry.template);
        }
    }
    var names = std.ArrayList(u8).empty;
    for (templates.entries, 0..) |entry, i| {
        if (i > 0) try names.appendSlice(arena, ", ");
        try names.appendSlice(arena, entry.name);
    }
    report("unknown template '{s}' (available: {s})", .{ name, names.items });
    return 1;
}

fn listTemplates(init: std.process.Init) u8 {
    var names_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &names_buf);
    for (templates.entries) |entry| {
        w.interface.print("{s}\t{s}\n", .{ entry.name, entry.description }) catch return stdoutErr(&w);
    }
    w.flush() catch return stdoutErr(&w);
    return 0;
}

fn readStdin(init: std.process.Init, arena: std.mem.Allocator) ![]u8 {
    var input = std.ArrayList(u8).empty;
    defer input.deinit(arena);
    const stdin_file = std.Io.File.stdin();
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = stdin_file.readStreaming(init.io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
        if (total > max_input) return error.StreamTooLong;
        try input.appendSlice(arena, buf[0..n]);
    }
    return input.toOwnedSlice(arena);
}

fn parseProfile(text: []const u8) ?oliver.OutputProfile {
    if (std.mem.eql(u8, text, "html")) return .html;
    if (std.mem.eql(u8, text, "xhtml")) return .xhtml;
    return null;
}

/// Parses a byte count, accepting a `k`/`m`/`g` suffix (case-insensitive).
fn parseSize(text: []const u8) error{Invalid}!usize {
    if (text.len == 0) return error.Invalid;
    var digits = text;
    var scale: usize = 1;
    switch (std.ascii.toLower(text[text.len - 1])) {
        'k' => {
            digits = text[0 .. text.len - 1];
            scale = 1024;
        },
        'm' => {
            digits = text[0 .. text.len - 1];
            scale = 1024 * 1024;
        },
        'g' => {
            digits = text[0 .. text.len - 1];
            scale = 1024 * 1024 * 1024;
        },
        else => {},
    }
    if (digits.len == 0) return error.Invalid;
    if (digits[0] == '-') return error.Invalid;
    const n = std.fmt.parseInt(u64, digits, 10) catch return error.Invalid;
    const scaled = std.math.mul(u64, n, scale) catch return error.Invalid;
    return std.math.cast(usize, scaled) orelse error.Invalid;
}

/// Wraps a rendered HTML fragment in a minimal document shell. The `title`
/// is HTML-escaped; the `css` hrefs, `head` lines, and `lang` tag pass
/// through verbatim (they may be URLs, paths, markup, or a BCP 47 tag —
/// validating them is the consumer's problem). `lang` lands on the root
/// element: `lang="…"` for HTML5, `lang` + `xml:lang` for XHTML. With no
/// title, no links, no head lines, and no lang the fragment is returned
/// untouched, so the no-flag output stays byte-identical to a bare
/// fragment.
///
/// The shell is assembled through a `Bounded` writer capped at `max_output`
/// (0 = unlimited), so shell overhead — escaped title, repeated links and
/// head lines — cannot smuggle an over-limit document past the cap: the
/// write that would cross it aborts assembly before the oversized document
/// exists. The cap trip comes back as `error.OutputLimitExceeded`; a
/// genuine allocation failure is `error.WriteFailed`. The returned slice is
/// allocated with `alloc`.
pub fn wrapDocument(alloc: std.mem.Allocator, fragment: []const u8, title: ?[]const u8, css: []const []const u8, head: []const []const u8, lang: ?[]const u8, profile: oliver.OutputProfile, max_output: usize) error{ WriteFailed, OutputLimitExceeded }![]const u8 {
    if (title == null and css.len == 0 and head.len == 0 and lang == null) return fragment;

    var buf = Bounded.init(alloc, max_output);
    errdefer buf.deinit();
    writeShell(&buf.writer, fragment, title, css, head, lang, profile) catch |e| switch (e) {
        error.WriteFailed => if (buf.exceeded) return error.OutputLimitExceeded else return error.WriteFailed,
    };
    return buf.written();
}

/// Writes the whole document — shell prefix, fragment, suffix — into `w`.
/// One function so every byte, escaped title included, passes through the
/// caller's bounded writer and charges the cap as it lands.
fn writeShell(w: *std.Io.Writer, fragment: []const u8, title: ?[]const u8, css: []const []const u8, head: []const []const u8, lang: ?[]const u8, profile: oliver.OutputProfile) std.Io.Writer.Error!void {
    switch (profile) {
        .html => {
            try w.writeAll("<!DOCTYPE html>\n");
            if (lang) |l| {
                try w.print("<html lang=\"{s}\">\n", .{l});
            } else {
                try w.writeAll("<html>\n");
            }
            try w.writeAll(
                \\<head>
                \\<meta charset="utf-8">
                \\
            );
            if (title) |t| {
                try w.writeAll("<title>");
                try escapeHtmlTo(w, t);
                try w.writeAll("</title>\n");
            }
            for (css) |href| try w.print("<link rel=\"stylesheet\" href=\"{s}\">\n", .{href});
            for (head) |line| try w.print("{s}\n", .{line});
        },
        .xhtml => {
            try w.writeAll("<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">\n");
            if (lang) |l| {
                try w.print("<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"{s}\" xml:lang=\"{s}\">\n", .{ l, l });
            } else {
                try w.writeAll("<html xmlns=\"http://www.w3.org/1999/xhtml\">\n");
            }
            try w.writeAll("<head>\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />\n");
            if (title) |t| {
                try w.writeAll("<title>");
                try escapeHtmlTo(w, t);
                try w.writeAll("</title>\n");
            }
            for (css) |href| try w.print("<link rel=\"stylesheet\" href=\"{s}\" />\n", .{href});
            for (head) |line| try w.print("{s}\n", .{line});
        },
        // The CLI only exposes html and xhtml; html4_strict was declined
        // upstream (see SPEC) and cannot reach the shell.
        .html4_strict => unreachable,
    }
    try w.writeAll("</head>\n<body>\n");
    try w.writeAll(fragment);
    if (fragment.len == 0 or fragment[fragment.len - 1] != '\n') try w.writeByte('\n');
    try w.writeAll("</body>\n</html>\n");
}

/// Escapes `& < > "` for HTML text content and attribute values, writing
/// straight into `w` — no intermediate buffer, so a bounded writer sees
/// every escaped byte as it is produced.
pub fn escapeHtmlTo(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(c),
        }
    }
}

/// Escapes `& < > "` and returns the bytes, allocated with `alloc`.
pub fn escapeHtml(alloc: std.mem.Allocator, text: []const u8) std.Io.Writer.Error![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    try escapeHtmlTo(&buf.writer, text);
    return buf.written();
}

/// A `std.Io.Writer.Allocating` twin whose total output is capped at
/// `max_output` bytes (0 = unlimited). Every write that would push the
/// total past the cap fails and sets `exceeded`, so the caller can tell an
/// output-limit trip from an allocation failure — through the writer
/// interface both are the same `error.WriteFailed`.
///
/// Capacity grows geometrically but never beyond the cap, so an over-limit
/// render aborts with at most the configured bytes of output storage: the
/// oversized document is never materialized. The cap covers emitted bytes
/// only — it is not a memory or CPU sandbox. Hosted callers still need
/// timeouts, concurrency limits, and OS-level resource controls.
pub const Bounded = struct {
    allocator: std.mem.Allocator,
    writer: std.Io.Writer,
    max_output: usize,
    exceeded: bool = false,

    pub fn init(allocator: std.mem.Allocator, max_output: usize) Bounded {
        return .{
            .allocator = allocator,
            .writer = .{ .buffer = &.{}, .vtable = &vtable },
            .max_output = max_output,
        };
    }

    pub fn deinit(b: *Bounded) void {
        if (b.writer.buffer.len == 0) return;
        b.allocator.rawFree(b.writer.buffer, alignment, @returnAddress());
        b.* = undefined;
    }

    /// Bytes written so far — at most `max_output` when the cap is set.
    pub fn written(b: *Bounded) []u8 {
        return b.writer.buffered();
    }

    const alignment: std.mem.Alignment = .of(u8);

    /// Fails the write. A cap crossing is reported as a limit trip; with
    /// no cap set (overflow of an unlimited render) it stays a plain
    /// allocation-style failure.
    fn failAppend(b: *Bounded) std.Io.Writer.Error {
        if (b.max_output != 0) b.exceeded = true;
        return error.WriteFailed;
    }

    fn ensureTotalCapacity(b: *Bounded, new_capacity: usize) std.Io.Writer.Error!void {
        const w = &b.writer;
        if (w.buffer.len >= new_capacity) return;
        var better_capacity: usize = undefined;
        if (b.max_output != 0) {
            if (new_capacity > b.max_output) return b.failAppend();
            // Geometric growth, clamped so storage never passes the cap.
            better_capacity = @min(std.ArrayList(u8).growCapacity(new_capacity), b.max_output);
        } else {
            better_capacity = std.ArrayList(u8).growCapacity(new_capacity);
        }
        const old_memory = w.buffer;
        if (old_memory.len > 0) {
            if (b.allocator.rawRemap(old_memory, alignment, better_capacity, @returnAddress())) |new| {
                w.buffer = new[0..better_capacity];
                return;
            }
        }
        const new_memory = (b.allocator.rawAlloc(better_capacity, alignment, @returnAddress()) orelse
            return error.WriteFailed)[0..better_capacity];
        const saved = old_memory[0..w.end];
        @memcpy(new_memory[0..saved.len], saved);
        if (old_memory.len != 0) b.allocator.rawFree(old_memory, alignment, @returnAddress());
        w.buffer = new_memory;
    }

    fn ensureUnusedCapacity(b: *Bounded, additional: usize) std.Io.Writer.Error!void {
        if (additional == 0) return;
        const needed = std.math.add(usize, b.writer.end, additional) catch return b.failAppend();
        return b.ensureTotalCapacity(needed);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const b: *Bounded = @fieldParentPtr("writer", w);
        // The exact number of bytes this call appends, checked before any
        // of them are stored.
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            total = std.math.add(usize, total, bytes.len) catch return b.failAppend();
        }
        const pattern = data[data.len - 1];
        const splat_len = std.math.mul(usize, pattern.len, splat) catch return b.failAppend();
        total = std.math.add(usize, total, splat_len) catch return b.failAppend();
        try b.ensureUnusedCapacity(total);
        for (data[0 .. data.len - 1]) |bytes| {
            @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
            w.end += bytes.len;
        }
        switch (pattern.len) {
            0 => {},
            1 => {
                @memset(w.buffer[w.end..][0..splat], pattern[0]);
                w.end += splat;
            },
            else => for (0..splat) |_| {
                @memcpy(w.buffer[w.end..][0..pattern.len], pattern);
                w.end += pattern.len;
            },
        }
        return total;
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        const b: *Bounded = @fieldParentPtr("writer", w);
        const total = std.math.add(usize, preserve, minimum_len) catch return b.failAppend();
        try b.ensureTotalCapacity(total);
        try b.ensureUnusedCapacity(minimum_len);
    }

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.noopFlush,
        .rebase = rebase,
    };
};

fn printStdout(init: std.process.Init, text: []const u8) u8 {
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    w.interface.writeAll(text) catch return stdoutErr(&w);
    w.flush() catch return stdoutErr(&w);
    return 0;
}

/// Reports a failed stdout write and returns the error exit code. The
/// writer interface only surfaces error.WriteFailed; the real errno is
/// kept on the File.Writer.
fn stdoutErr(w: *std.Io.File.Writer) u8 {
    report("cannot write to stdout: {s}", .{@errorName(w.err orelse error.WriteFailed)});
    return 1;
}

fn usage(init: std.process.Init, msg: []const u8) u8 {
    _ = init;
    report("{s}", .{msg});
    report("usage: dogbed render <template.knap> [...] | dogbed template <name> | dogbed init  (see --help)", .{});
    return 1;
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("dogbed: " ++ fmt ++ "\n", args);
}
