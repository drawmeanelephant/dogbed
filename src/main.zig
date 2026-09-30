//! dogbed CLI — a document compiler, not a CMS.
//!
//!     dogbed render <template.knap> [--data <data.json>] [--profile html|xhtml] [--max-output <bytes>]
//!     dogbed template <name>
//!     dogbed --help
//!     dogbed --version
//!
//! Pipeline: Knap template + JSON data --k4o--> Textile --oliver--> HTML.
//! By default the output is a bare HTML fragment; --title or --css wraps it
//! in a minimal document shell.
//!
//! Exit codes: 0 = success, 1 = any error. On error the message goes to
//! stderr and stdout stays empty — rendering is buffered, so partially
//! rendered output is never emitted.

const std = @import("std");
const kt = @import("k4o");
const oliver = @import("oliver");
const templates = @import("templates");
const build_options = @import("build_options");

const max_input = 16 * 1024 * 1024;

const usage_text =
    \\dogbed — a document compiler. Knap templates in, HTML documents out.
    \\
    \\Usage:
    \\  dogbed render <template.knap> [--data <data.json>] [--profile html|xhtml]
    \\  dogbed template <name>
    \\  dogbed --help
    \\  dogbed --version
    \\
    \\Commands:
    \\  render              Render a Knap template (with JSON data) to HTML.
    \\  template <name>     Print an embedded starter template to stdout, so
    \\                      you copy it and own it. `dogbed template --list`
    \\                      shows the names: verdict, release-notes,
    \\                      reading-note.
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
    \\                      Either --title or --css switches output from a
    \\                      bare fragment to a full document.
    \\  --head <html>       Splice one verbatim line into the shell's
    \\                      <head> (meta tags, favicon links). Repeatable,
    \\                      kept in order; the markup passes through
    \\                      unvalidated — escape your own attributes.
    \\  --max-output, -m <bytes>
    \\                      Ceiling on the emitted document in bytes, shell
    \\                      included (it also bounds the intermediate Textile
    \\                      render). Nested loops multiply, so a small
    \\                      template over modest data can ask for far more
    \\                      than you expect. Default 268435456 (256 MiB);
    \\                      0 means no limit.
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
        try printStdout(init, usage_text);
        return 0;
    }
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-v")) {
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "dogbed {s}\n", .{build_options.version});
        try printStdout(init, text);
        return 0;
    }
    if (!std.mem.eql(u8, first, "render")) {
        if (std.mem.eql(u8, first, "template")) return templateCmd(init, args.items[1..]);
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
    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        const arg = args.items[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printStdout(init, usage_text);
            return 0;
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

    var html_buf = std.Io.Writer.Allocating.init(arena);
    oliver.html.render(arena, &html_buf.writer, &result.document, .{ .profile = profile }) catch |e| {
        report("render: {s}", .{@errorName(e)});
        return 1;
    };

    // Optional document shell: --title/--css/--head wrap the fragment;
    // without any of them the fragment is emitted byte-identical to a bare
    // oliver render.
    var final: []const u8 = html_buf.written();
    if (title != null or css.items.len > 0 or head.items.len > 0) {
        // Writer errors on an allocating buffer are allocation failures.
        final = wrapDocument(arena, final, title, css.items, head.items, profile) catch {
            report("out of memory", .{});
            return 1;
        };
    }

    // The cap covers the final document, shell included.
    if (max_output != 0 and final.len > max_output) {
        report("output ({d} bytes) exceeds --max-output ({d})", .{ final.len, max_output });
        return 1;
    }

    // Buffered render complete: emit in one write so that an error never
    // produces half-rendered output.
    var out_buf: [8192]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);
    w.interface.writeAll(final) catch return 1;
    w.flush() catch return 1;
    return 0;
}

fn templateCmd(init: std.process.Init, rest: []const []const u8) !u8 {
    const arena = init.arena.allocator();

    if (rest.len == 0) return listTemplates(init);
    if (rest.len > 1) return usage(init, "expected one template name (try `dogbed template --list`)");
    const name = rest[0];
    if (std.mem.eql(u8, name, "--list") or std.mem.eql(u8, name, "list")) return listTemplates(init);
    if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
        try printStdout(init, usage_text);
        return 0;
    }
    for (templates.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            try printStdout(init, entry.template);
            return 0;
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

fn listTemplates(init: std.process.Init) !u8 {
    var names_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &names_buf);
    for (templates.entries) |entry| {
        w.interface.print("{s}\t{s}\n", .{ entry.name, entry.description }) catch return 1;
    }
    w.flush() catch return 1;
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
/// is HTML-escaped; the `css` hrefs and the `head` lines pass through
/// verbatim (they may be URLs, paths, or raw markup — validating them is
/// the consumer's problem). With no title, no links, and no head lines the
/// fragment is returned untouched, so the no-flag output stays
/// byte-identical to a bare fragment.
pub fn wrapDocument(alloc: std.mem.Allocator, fragment: []const u8, title: ?[]const u8, css: []const []const u8, head: []const []const u8, profile: oliver.OutputProfile) std.Io.Writer.Error![]const u8 {
    if (title == null and css.len == 0 and head.len == 0) return fragment;

    var buf = std.Io.Writer.Allocating.init(alloc);
    const w = &buf.writer;
    switch (profile) {
        .html => {
            try w.writeAll(
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\<meta charset="utf-8">
                \\
            );
            if (title) |t| try w.print("<title>{s}</title>\n", .{try escapeHtml(alloc, t)});
            for (css) |href| try w.print("<link rel=\"stylesheet\" href=\"{s}\">\n", .{href});
            for (head) |line| try w.print("{s}\n", .{line});
        },
        .xhtml => {
            try w.writeAll("<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">\n<html xmlns=\"http://www.w3.org/1999/xhtml\">\n<head>\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />\n");
            if (title) |t| try w.print("<title>{s}</title>\n", .{try escapeHtml(alloc, t)});
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
    return buf.written();
}

/// Escapes `& < > "` for HTML text content and attribute values.
pub fn escapeHtml(alloc: std.mem.Allocator, text: []const u8) std.Io.Writer.Error![]const u8 {
    var buf = std.Io.Writer.Allocating.init(alloc);
    for (text) |c| {
        switch (c) {
            '&' => try buf.writer.writeAll("&amp;"),
            '<' => try buf.writer.writeAll("&lt;"),
            '>' => try buf.writer.writeAll("&gt;"),
            '"' => try buf.writer.writeAll("&quot;"),
            else => try buf.writer.writeByte(c),
        }
    }
    return buf.written();
}

fn printStdout(init: std.process.Init, text: []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &out_buf);
    try w.interface.writeAll(text);
    try w.flush();
}

fn usage(init: std.process.Init, msg: []const u8) u8 {
    _ = init;
    report("{s}", .{msg});
    report("usage: dogbed render <template.knap> [...] | dogbed template <name>  (see --help)", .{});
    return 1;
}

fn report(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("dogbed: " ++ fmt ++ "\n", args);
}
