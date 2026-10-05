//! dogbed test suite: the pipeline is the product, so the smoke test runs
//! the whole thing — Knap template + JSON --k4o--> Textile --oliver--> HTML.

const std = @import("std");
const kt = @import("k4o");
const oliver = @import("oliver");
const templates = @import("templates");
const scaffold = @import("scaffold");
const build_options = @import("build_options");
const cli = @import("main");

test "pipeline: knap template renders through textile to html" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const template = "{{ title | h1 }}\n\n{{ subtitle | italic }}\n";
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"title\":\"The Machine Stops\",\"subtitle\":\"A reading note\"}",
        .{},
    );
    defer parsed.deinit();

    // Stage 1: k4o.
    var d = kt.Diagnostic{};
    const textile = try kt.render(alloc, template, parsed.value, &d);
    try std.testing.expect(std.mem.indexOf(u8, textile, "h1. The Machine Stops") != null);
    try std.testing.expect(std.mem.indexOf(u8, textile, "_A reading note_") != null);

    // Stage 2: oliver. The document borrows the textile bytes, which the
    // arena keeps alive past the parse result.
    var result = try oliver.parse(alloc, textile, .textile, .{});
    defer result.deinit();

    var html_buf = std.Io.Writer.Allocating.init(alloc);
    try oliver.html.render(alloc, &html_buf.writer, &result.document, .{});
    const html = html_buf.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "The Machine Stops") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<em>A reading note</em>") != null);
}

test "pipeline: xhtml profile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"title\":\"Hi\"}",
        .{},
    );
    defer parsed.deinit();

    var d = kt.Diagnostic{};
    const textile = try kt.render(alloc, "{{ title | h1 }}\n", parsed.value, &d);
    var result = try oliver.parse(alloc, textile, .textile, .{});
    defer result.deinit();

    var html_buf = std.Io.Writer.Allocating.init(alloc);
    try oliver.html.render(alloc, &html_buf.writer, &result.document, .{ .profile = .xhtml });
    try std.testing.expect(std.mem.indexOf(u8, html_buf.written(), "<h1") != null);
}

test "shell: no title and no css returns the fragment untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const fragment = "<h1>hi</h1>\n<p>body</p>\n";
    const out = try cli.wrapDocument(alloc, fragment, null, &.{}, &.{}, null, .html, 0);
    try std.testing.expectEqualStrings(fragment, out);
}

test "shell: title wraps the fragment and escapes the title" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const out = try cli.wrapDocument(alloc, "<p>hi</p>\n", "Art & \"<b>Science</b>\"", &.{}, &.{}, null, .html, 0);
    try std.testing.expectEqualStrings(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<title>Art &amp; &quot;&lt;b&gt;Science&lt;/b&gt;&quot;</title>
        \\</head>
        \\<body>
        \\<p>hi</p>
        \\</body>
        \\</html>
        \\
    , out);
}

test "shell: css without title gives a shell with no title element, links in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const one = try cli.wrapDocument(alloc, "<p>hi</p>\n", null, &.{"a.css"}, &.{}, null, .html, 0);
    try std.testing.expect(std.mem.indexOf(u8, one, "<title") == null);
    try std.testing.expect(std.mem.indexOf(u8, one, "<link rel=\"stylesheet\" href=\"a.css\">") != null);

    const two = try cli.wrapDocument(alloc, "<p>hi</p>\n", null, &.{ "a.css", "b.css" }, &.{}, null, .html, 0);
    try std.testing.expect(std.mem.indexOf(u8, two, "<title") == null);
    const a = std.mem.indexOf(u8, two, "href=\"a.css\"").?;
    const b = std.mem.indexOf(u8, two, "href=\"b.css\"").?;
    try std.testing.expect(a < b);
}

test "shell: xhtml profile emits the XHTML 1.0 Strict shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const out = try cli.wrapDocument(alloc, "<p>hi</p>\n", "T", &.{"c.css"}, &.{}, null, .xhtml, 0);
    try std.testing.expect(std.mem.startsWith(u8, out, "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">"));
    try std.testing.expect(std.mem.indexOf(u8, out, "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<meta charset") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<link rel=\"stylesheet\" href=\"c.css\" />") != null);
}

test "shell: fragment without a trailing newline still lands on its own body line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const out = try cli.wrapDocument(alloc, "<p>hi</p>", "T", &.{}, &.{}, null, .html, 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "<p>hi</p>\n</body>") != null);
}

test "shell: head lines splice into the head verbatim, in order, and trigger the shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const out = try cli.wrapDocument(alloc, "<p>hi</p>\n", null, &.{}, &.{
        "<link rel=\"icon\" href=\"favicon.png\">",
        "<meta property=\"og:title\" content=\"dogbed\">",
    }, null, .html, 0);
    try std.testing.expect(std.mem.indexOf(u8, out, "<title") == null);
    const icon = std.mem.indexOf(u8, out, "<link rel=\"icon\"").?;
    const og = std.mem.indexOf(u8, out, "<meta property").?;
    try std.testing.expect(icon < og);
    try std.testing.expect(std.mem.indexOf(u8, out, "<!DOCTYPE html>") != null);
}

test "shell: lang lands on the root element in both profiles" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const html = try cli.wrapDocument(alloc, "<p>hi</p>\n", null, &.{}, &.{}, "en", .html, 0);
    try std.testing.expect(std.mem.startsWith(u8, html, "<!DOCTYPE html>\n<html lang=\"en\">\n<head>"));

    // XHTML carries both the human-readable lang and its XML twin.
    const xhtml = try cli.wrapDocument(alloc, "<p>hi</p>\n", null, &.{}, &.{}, "pt-BR", .xhtml, 0);
    try std.testing.expect(std.mem.indexOf(u8, xhtml, "<html xmlns=\"http://www.w3.org/1999/xhtml\" lang=\"pt-BR\" xml:lang=\"pt-BR\">") != null);
}

test "shell: lang alone triggers the shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // The lang attribute can only land on the shell's root element, so
    // --lang with nothing else is still a full document.
    const out = try cli.wrapDocument(alloc, "<p>hi</p>\n", null, &.{}, &.{}, "en", .html, 0);
    try std.testing.expect(std.mem.startsWith(u8, out, "<!DOCTYPE html>"));
    try std.testing.expect(std.mem.indexOf(u8, out, "<html lang=\"en\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<title") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "<body>\n<p>hi</p>\n</body>\n</html>\n"));
}

test "shell: no lang keeps the root element byte-identical in both profiles" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const html = try cli.wrapDocument(alloc, "<p>hi</p>\n", "T", &.{}, &.{}, null, .html, 0);
    try std.testing.expect(std.mem.indexOf(u8, html, "\n<html>\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "lang=") == null);

    const xhtml = try cli.wrapDocument(alloc, "<p>hi</p>\n", "T", &.{}, &.{}, null, .xhtml, 0);
    try std.testing.expect(std.mem.indexOf(u8, xhtml, "<html xmlns=\"http://www.w3.org/1999/xhtml\">\n") != null);
}

test "templates: names are unique" {
    for (templates.entries, 0..) |a, i| {
        for (templates.entries[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a.name, b.name));
        }
    }
}

test "templates: every starter renders through the full pipeline with its example data" {
    for (templates.entries) |entry| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const alloc = arena_state.allocator();

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, entry.example_data, .{});
        var d = kt.Diagnostic{};
        const textile = try kt.render(alloc, entry.template, parsed, &d);
        try std.testing.expect(textile.len > 0);

        var result = try oliver.parse(alloc, textile, .textile, .{});
        defer result.deinit();
        var html_buf = std.Io.Writer.Allocating.init(alloc);
        try oliver.html.render(alloc, &html_buf.writer, &result.document, .{});
        const html = html_buf.written();
        try std.testing.expect(std.mem.indexOf(u8, html, "<h1") != null);
    }
}

// -- dogbed init --

/// A temp dir plus captured report output from running `cli.scaffoldSite`
/// in it. `run` may be called more than once on the same dir — that is the
/// point: init must be idempotent.
const InitRun = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,
    out: []const u8,
    err_out: []const u8,

    const io = std.testing.io;

    fn start() InitRun {
        return .{
            .tmp = std.testing.tmpDir(.{}),
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .out = "",
            .err_out = "",
        };
    }

    fn deinit(self: *InitRun) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    /// Runs scaffoldSite in this run's dir, replacing the captured output.
    /// Report lines from earlier runs stay readable (same arena). Output is
    /// captured even when the run fails — failure lines matter most.
    fn run(self: *InitRun, dirs: []const []const u8, files: []const scaffold.File) !void {
        const arena = self.arena_state.allocator();
        var out_buf = std.Io.Writer.Allocating.init(arena);
        var err_buf = std.Io.Writer.Allocating.init(arena);
        const result = cli.scaffoldSite(self.tmp.dir, io, arena, &out_buf.writer, &err_buf.writer, dirs, files);
        self.out = out_buf.written();
        self.err_out = err_buf.written();
        return result;
    }

    fn readFile(self: *InitRun, path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(io, path, self.arena_state.allocator(), .limited(1 << 20));
    }

    fn writeFile(self: *InitRun, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = path, .data = data });
    }

    fn expectFile(self: *InitRun, path: []const u8, want: []const u8) !void {
        try std.testing.expectEqualStrings(want, try self.readFile(path));
    }

    fn expectOut(self: *InitRun, needle: []const u8) !void {
        try std.testing.expect(std.mem.indexOf(u8, self.out, needle) != null);
    }

    fn expectErr(self: *InitRun, needle: []const u8) !void {
        try std.testing.expect(std.mem.indexOf(u8, self.err_out, needle) != null);
    }
};

test "init: a fresh dir gets the whole skeleton, byte-exact, build.sh executable" {
    var run = InitRun.start();
    defer run.deinit();
    try run.run(&scaffold.dirs, &scaffold.files);

    for (scaffold.files) |f| {
        try run.expectFile(f.path, f.content);
    }
    const build_sh = try run.tmp.dir.statFile(InitRun.io, "build.sh", .{});
    try std.testing.expect(@intFromEnum(build_sh.permissions) & 0o111 != 0);
    const routes = try run.tmp.dir.statFile(InitRun.io, "routes.txt", .{});
    try std.testing.expect(@intFromEnum(routes.permissions) & 0o111 == 0);

    try run.expectOut("created  build.sh\n");
    try run.expectOut("created  src/\n");
    try run.expectOut("init: 12 created (3 dirs, 9 files), 0 kept, 0 superseded");
}

test "init: a second run keeps everything and creates nothing" {
    var run = InitRun.start();
    defer run.deinit();
    try run.run(&scaffold.dirs, &scaffold.files);
    const layout_after_first = try run.readFile("src/layout.knap");
    try run.run(&scaffold.dirs, &scaffold.files);

    try run.expectOut("kept     build.sh (exists — init never overwrites)");
    try run.expectOut("init: 9 kept, nothing created — the scaffold is already complete, nothing touched");
    try run.expectFile("src/layout.knap", layout_after_first);
}

test "init: a user's file is kept byte-identical" {
    var run = InitRun.start();
    defer run.deinit();
    try run.writeFile("README.md", "mine, not the scaffold's\n");
    try run.run(&scaffold.dirs, &scaffold.files);

    try run.expectFile("README.md", "mine, not the scaffold's\n");
    try run.expectOut("kept     README.md (exists — init never overwrites)");
}

test "init: a directory squatting on a file path fails loudly and survives" {
    var run = InitRun.start();
    defer run.deinit();
    try run.tmp.dir.createDirPath(InitRun.io, "routes.txt");

    try std.testing.expectError(error.ScaffoldFailed, run.run(&scaffold.dirs, &scaffold.files));
    try run.expectErr("init: 'routes.txt' exists as a directory — move it aside");
    const st = try run.tmp.dir.statFile(InitRun.io, "routes.txt", .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, st.kind);
}

test "init: a superseding entry archives its old scaffold file and writes the new" {
    const files = [_]scaffold.File{.{ .path = "src/index.knap", .content = "new bytes\n", .supersedes = "old bytes\n" }};
    var run = InitRun.start();
    defer run.deinit();
    try run.tmp.dir.createDirPath(InitRun.io, "src");
    try run.writeFile("src/index.knap", "old bytes\n");
    try run.run(&.{}, &files);

    try run.expectFile("src/index.knap", "new bytes\n");
    try run.expectOut("archived src/index.knap -> .dogbed-archive/");
    // The old file lives in the archive, byte-identical — bagged, not curbed.
    var archive = try run.tmp.dir.openDir(InitRun.io, scaffold.archive_dirname, .{ .iterate = true });
    defer archive.close(InitRun.io);
    var it = archive.iterate();
    var archived_name: ?[]const u8 = null;
    const arena = run.arena_state.allocator();
    while (try it.next(InitRun.io)) |entry| {
        if (entry.kind == .directory) archived_name = try arena.dupe(u8, entry.name);
    }
    try std.testing.expect(archived_name != null);
    const archived = try std.fmt.allocPrint(arena, "{s}/{s}/index.knap", .{ scaffold.archive_dirname, archived_name.? });
    try run.expectFile(archived, "old bytes\n");
}

test "init: supersede leaves a modified file alone" {
    const files = [_]scaffold.File{.{ .path = "src/index.knap", .content = "new bytes\n", .supersedes = "old bytes\n" }};
    var run = InitRun.start();
    defer run.deinit();
    try run.tmp.dir.createDirPath(InitRun.io, "src");
    try run.writeFile("src/index.knap", "the user's own edits\n");
    try run.run(&.{}, &files);

    try run.expectFile("src/index.knap", "the user's own edits\n");
    try run.expectOut("kept     src/index.knap (modified since it was scaffolded");
}

test "scaffold: routes, files, and rendered pages all agree" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const scaffold_files = &scaffold.files;
    const find = struct {
        fn content(files: []const scaffold.File, path: []const u8) ?[]const u8 {
            for (files) |f| {
                if (std.mem.eql(u8, f.path, path)) return f.content;
            }
            return null;
        }
    }.content;

    // Every route has its template and data; every routed page renders
    // through the full pipeline.
    const routes = find(scaffold_files, "routes.txt") orelse return error.TestUnexpectedResult;
    var routed: usize = 0;
    var lines = std.mem.splitScalar(u8, routes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.TestUnexpectedResult;
        const name = line[0..tab];
        const knap_path = try std.fmt.allocPrint(alloc, "src/{s}.knap", .{name});
        const data_path = try std.fmt.allocPrint(alloc, "data/{s}.json", .{name});
        const knap = find(scaffold_files, knap_path) orelse return error.TestUnexpectedResult;
        const data_json = find(scaffold_files, data_path) orelse return error.TestUnexpectedResult;

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, data_json, .{});
        var d = kt.Diagnostic{};
        const textile = try kt.render(alloc, knap, parsed, &d);
        var result = try oliver.parse(alloc, textile, .textile, .{});
        defer result.deinit();
        var html_buf = std.Io.Writer.Allocating.init(alloc);
        try oliver.html.render(alloc, &html_buf.writer, &result.document, .{});
        try std.testing.expect(std.mem.indexOf(u8, html_buf.written(), "<h1") != null);
        routed += 1;
    }
    try std.testing.expect(routed >= 2);

    // Every routed template other than layout.knap is in the route table,
    // and layout.knap — the page frame, not a route — still renders.
    const layout = find(scaffold_files, "src/layout.knap") orelse return error.TestUnexpectedResult;
    const frame_data = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"title":"T","intro":"I","body":"B"}
    , .{});
    var d = kt.Diagnostic{};
    const textile = try kt.render(alloc, layout, frame_data, &d);
    var result = try oliver.parse(alloc, textile, .textile, .{});
    defer result.deinit();
    var html_buf = std.Io.Writer.Allocating.init(alloc);
    try oliver.html.render(alloc, &html_buf.writer, &result.document, .{});
    try std.testing.expect(std.mem.indexOf(u8, html_buf.written(), "<h1>T</h1>") != null);
}

// -- --max-output: bounded rendering (issue #16) --

/// Where an over-limit render stopped. `ok` means the whole pipeline fit
/// under the cap.
const Trip = union(enum) {
    ok: []const u8,
    k4o_stage,
    html_stage,
    shell_stage,
};

/// Runs the same bounded pipeline `dogbed render` does — k4o, oliver, then
/// the optional shell, every output stage capped at `max_output` (0 =
/// unlimited). Mirrors src/main.zig's render flow; the tests below hold
/// them in lockstep.
fn renderBounded(
    alloc: std.mem.Allocator,
    template: []const u8,
    data_json: []const u8,
    profile: oliver.OutputProfile,
    max_output: usize,
    title: ?[]const u8,
    css: []const []const u8,
    head: []const []const u8,
    lang: ?[]const u8,
) !Trip {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, data_json, .{});
    var d = kt.Diagnostic{};
    const textile = kt.renderWithLimit(alloc, template, parsed, &d, max_output) catch |e| switch (e) {
        error.Template => return .k4o_stage,
        error.OutOfMemory => return error.OutOfMemory,
    };
    var result = try oliver.parse(alloc, textile, .textile, .{});
    defer result.deinit();

    var html_out = cli.Bounded.init(alloc, max_output);
    oliver.html.render(alloc, &html_out.writer, &result.document, .{ .profile = profile }) catch |e| {
        if (e == error.WriteFailed and html_out.exceeded) return .html_stage;
        return e;
    };
    const fragment = html_out.written();

    const shelled = title != null or css.len > 0 or head.len > 0 or lang != null;
    if (!shelled) return .{ .ok = fragment };
    if (cli.wrapDocument(alloc, fragment, title, css, head, lang, profile, max_output)) |doc| {
        return .{ .ok = doc };
    } else |e| switch (e) {
        error.OutputLimitExceeded => return .shell_stage,
        error.WriteFailed => return error.WriteFailed,
    }
}

test "bounded writer: stops at the cap, one byte over trips" {
    var b = cli.Bounded.init(std.testing.allocator, 8);
    defer b.deinit();
    try b.writer.writeAll("12345678");
    try std.testing.expectEqualStrings("12345678", b.written());
    // Exactly at the cap is fine; the write that crosses it fails and is
    // not stored.
    try std.testing.expectError(error.WriteFailed, b.writer.writeAll("9"));
    try std.testing.expect(b.exceeded);
    try std.testing.expectEqualStrings("12345678", b.written());
    // Storage never grew past the cap — the point of the fix.
    try std.testing.expect(b.writer.buffer.len <= 8);
}

test "bounded writer: print and repeated-byte paths charge the exact total" {
    var b = cli.Bounded.init(std.testing.allocator, 16);
    defer b.deinit();
    try b.writer.print("{d}!", .{12345});
    try b.writer.splatByteAll('x', 10);
    try std.testing.expectEqualStrings("12345!xxxxxxxxxx", b.written());
    try std.testing.expectError(error.WriteFailed, b.writer.splatByteAll('y', 2));
    try std.testing.expect(b.exceeded);
    try std.testing.expect(b.writer.buffer.len <= 16);
}

test "bounded writer: zero cap keeps the old unbounded behavior" {
    var b = cli.Bounded.init(std.testing.allocator, 0);
    defer b.deinit();
    try b.writer.splatByteAll('x', 1000);
    try std.testing.expectEqual(@as(usize, 1000), b.written().len);
    try std.testing.expect(!b.exceeded);
}

test "max-output: html escaping expansion trips during the html stage" {
    inline for (.{ oliver.OutputProfile.html, oliver.OutputProfile.xhtml }) |profile| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const alloc = arena_state.allocator();

        // The issue's repro shape: ~1 KiB of Textile passes the k4o stage,
        // escaping expands it past 4 KiB of HTML.
        const template = "{{ body }}\n";
        const data = "{\"body\":\"" ++ "&" ** 1000 ++ "\"}";
        const trip = try renderBounded(alloc, template, data, profile, 4096, null, &.{}, &.{}, null);
        try std.testing.expectEqual(Trip.html_stage, trip);
    }
}

test "max-output: the html stage stops storing at the cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"body\":\"" ++ "&" ** 1000 ++ "\"}", .{});
    var d = kt.Diagnostic{};
    const textile = try kt.renderWithLimit(alloc, "{{ body }}\n", parsed, &d, 4096);
    var result = try oliver.parse(alloc, textile, .textile, .{});
    defer result.deinit();

    var html_out = cli.Bounded.init(alloc, 4096);
    try std.testing.expectError(error.WriteFailed, oliver.html.render(alloc, &html_out.writer, &result.document, .{}));
    try std.testing.expect(html_out.exceeded);
    // No oversized document ever existed: storage and content both stayed
    // under the cap. A final stdout.len == 0 assertion alone would not
    // prove this.
    try std.testing.expect(html_out.writer.buffer.len <= 4096);
    try std.testing.expect(html_out.written().len <= 4096);
}

test "max-output: shell overhead trips during shell assembly, both profiles" {
    inline for (.{ oliver.OutputProfile.html, oliver.OutputProfile.xhtml }) |profile| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const alloc = arena_state.allocator();

        // The fragment fits; the shell pushes the document over. Each
        // trigger aborts wrapDocument with the limit error, not OOM.
        const fragment = "<p>hi</p>\n";
        // (a) escaped title text: 40 & escape into 200 bytes of &amp;
        try std.testing.expectError(
            error.OutputLimitExceeded,
            cli.wrapDocument(alloc, fragment, "&" ** 40, &.{}, &.{}, null, profile, 100),
        );
        // (b) repeated css entries
        const css8 = &([1][]const u8{"a.css"} ** 8);
        try std.testing.expectError(
            error.OutputLimitExceeded,
            cli.wrapDocument(alloc, fragment, null, css8, &.{}, null, profile, 100),
        );
        // (c) repeated head entries
        const head8 = &([1][]const u8{"<meta property=\"og:title\" content=\"dogbed\">"} ** 8);
        try std.testing.expectError(
            error.OutputLimitExceeded,
            cli.wrapDocument(alloc, fragment, null, &.{}, head8, null, profile, 100),
        );
    }
}

test "max-output: html stage boundary — exact cap passes, one byte over trips" {
    inline for (.{ oliver.OutputProfile.html, oliver.OutputProfile.xhtml }) |profile| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const alloc = arena_state.allocator();

        // "&" escapes to "&amp;" and lands in a paragraph —
        // "<p>&amp;</p>\n", 11 bytes from a 1-byte Textile: the html stage
        // owns this boundary. Exactly at the cap succeeds and is
        // byte-identical to an unlimited render; one byte under trips.
        const unlimited = try renderBounded(alloc, "{{ body }}", "{\"body\":\"&\"}", profile, 0, null, &.{}, &.{}, null);
        try std.testing.expectEqualStrings("<p>&amp;</p>\n", unlimited.ok);
        const exact = try renderBounded(alloc, "{{ body }}", "{\"body\":\"&\"}", profile, unlimited.ok.len, null, &.{}, &.{}, null);
        try std.testing.expectEqualStrings("<p>&amp;</p>\n", exact.ok);
        const over = try renderBounded(alloc, "{{ body }}", "{\"body\":\"&\"}", profile, unlimited.ok.len - 1, null, &.{}, &.{}, null);
        try std.testing.expectEqual(Trip.html_stage, over);
    }
}

test "max-output: shell boundary — exact cap passes, one byte over trips" {
    inline for (.{ oliver.OutputProfile.html, oliver.OutputProfile.xhtml }) |profile| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const alloc = arena_state.allocator();

        const flags = .{ "T", @as([]const []const u8, &.{"a.css"}), @as([]const []const u8, &.{}), @as(?[]const u8, null) };
        const unlimited = try renderBounded(alloc, "{{ body }}", "{\"body\":\"&\"}", profile, 0, flags[0], flags[1], flags[2], flags[3]);
        const n = unlimited.ok.len;
        // The fragment (<p>&amp;</p>, 14 bytes) leaves room for the shell,
        // so the one-byte-over render gets all the way to shell assembly.
        try std.testing.expect(n - 1 > 14);
        const exact = try renderBounded(alloc, "{{ body }}", "{\"body\":\"&\"}", profile, n, flags[0], flags[1], flags[2], flags[3]);
        try std.testing.expectEqualStrings(unlimited.ok, exact.ok);
        const over = try renderBounded(alloc, "{{ body }}", "{\"body\":\"&\"}", profile, n - 1, flags[0], flags[1], flags[2], flags[3]);
        try std.testing.expectEqual(Trip.shell_stage, over);
    }
}

test "max-output: under-limit renders stay byte-identical to unlimited" {
    inline for (.{ oliver.OutputProfile.html, oliver.OutputProfile.xhtml }) |profile| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const alloc = arena_state.allocator();

        const template = "{{ title | h1 }}\n\n{{ body }}\n";
        const data = "{\"title\":\"T & U\",\"body\":\"" ++ "&" ** 200 ++ "\"}";
        // Bare fragment.
        const bare = try renderBounded(alloc, template, data, profile, 0, null, &.{}, &.{}, null);
        const bare_capped = try renderBounded(alloc, template, data, profile, 1 << 20, null, &.{}, &.{}, null);
        try std.testing.expectEqualStrings(bare.ok, bare_capped.ok);
        // Full document.
        const doc = try renderBounded(alloc, template, data, profile, 0, "T & U", &.{ "a.css", "b.css" }, &.{"<meta charset=\"utf-8\">"}, "en");
        const doc_capped = try renderBounded(alloc, template, data, profile, 1 << 20, "T & U", &.{ "a.css", "b.css" }, &.{"<meta charset=\"utf-8\">"}, "en");
        try std.testing.expectEqualStrings(doc.ok, doc_capped.ok);
    }
}

test "max-output: zero cap retains the documented unlimited semantics" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const template = "{{ body }}\n{{ body }}\n{{ body }}\n";
    const data = "{\"body\":\"" ++ "&" ** 100000 ++ "\"}";
    const trip = try renderBounded(alloc, template, data, .html, 0, null, &.{}, &.{}, null);
    // ~1.5 MB of escaped HTML renders fine with no cap.
    try std.testing.expect(trip.ok.len > 1_000_000);
}

test "max-output: allocation failure stays distinct from a limit trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Out of memory: the plain write failure, reported as such.
    try std.testing.expectError(
        error.WriteFailed,
        cli.wrapDocument(std.testing.failing_allocator, "<p>hi</p>\n", "T", &.{}, &.{}, null, .html, 1 << 20),
    );
    // Over the cap: the distinguishable limit error.
    try std.testing.expectError(
        error.OutputLimitExceeded,
        cli.wrapDocument(alloc, "<p>hi</p>\n", "&" ** 100, &.{}, &.{}, null, .html, 50),
    );
}

