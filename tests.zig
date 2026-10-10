//! dogbed test suite: the pipeline is the product, so the smoke test runs
//! the whole thing — Knap template + JSON --k4o--> Textile --oliver--> HTML.

const std = @import("std");
const kt = @import("k4o");
const oliver = @import("oliver");
const templates = @import("templates");
const scaffold = @import("scaffold");
const build_options = @import("build_options");
const cli = @import("main");

/// `build_options.dogbed_exe` is the make-time-resolved install path —
/// build-root-relative for the default zig-out prefix, absolute under a
/// `--prefix` override. Tests spawn it from scratch dirs, so absolutize it
/// against `repo_root` when needed.
fn dogbedExe(alloc: std.mem.Allocator) ![]const u8 {
    if (std.Io.Dir.path.isAbsolute(build_options.dogbed_exe)) return build_options.dogbed_exe;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ build_options.repo_root, build_options.dogbed_exe });
}

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

// -- init atomicity: a failed write leaves no partial file (issue #20) --

/// How many streaming file writes still succeed before every write starts
/// failing with NoSpaceLeft — an injected disk-full.
var writes_left_before_enospc: usize = std.math.maxInt(usize);
var enospc_vtable: std.Io.VTable = undefined;
var enospc_vtable_ready = false;

/// `std.testing.io` with `enospcOperate` patched in: scaffoldSite sees a
/// disk that fills up after `budget` successful file writes.
fn diskFullIo(budget: usize) std.Io {
    if (!enospc_vtable_ready) {
        enospc_vtable = std.testing.io.vtable.*;
        enospc_vtable.operate = enospcOperate;
        enospc_vtable_ready = true;
    }
    writes_left_before_enospc = budget;
    return .{ .userdata = std.testing.io.userdata, .vtable = &enospc_vtable };
}

fn enospcOperate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    switch (operation) {
        .file_write_streaming => {
            if (writes_left_before_enospc == 0) return .{ .file_write_streaming = error.NoSpaceLeft };
            writes_left_before_enospc -= 1;
        },
        else => {},
    }
    return std.testing.io.vtable.operate(userdata, operation);
}

test "init: a write failure mid-scaffold leaves earlier files whole and no temp litter" {
    var run = InitRun.start();
    defer run.deinit();

    // README.md lands whole; the disk fills while routes.txt is written.
    const arena = run.arena_state.allocator();
    var out_buf = std.Io.Writer.Allocating.init(arena);
    var err_buf = std.Io.Writer.Allocating.init(arena);
    const result = cli.scaffoldSite(run.tmp.dir, diskFullIo(1), arena, &out_buf.writer, &err_buf.writer, &scaffold.dirs, &scaffold.files);
    run.out = out_buf.written();
    run.err_out = err_buf.written();
    try std.testing.expectError(error.ScaffoldFailed, result);
    try run.expectErr("init: cannot write 'routes.txt': NoSpaceLeft");

    // The installed file stays whole, the failed path simply doesn't exist
    // — no truncated file and no temp litter for a re-run to keep or trip
    // over.
    const readme = for (scaffold.files) |f| {
        if (std.mem.eql(u8, f.path, "README.md")) break f.content;
    } else unreachable;
    try run.expectFile("README.md", readme);
    try std.testing.expectError(error.FileNotFound, run.readFile("routes.txt"));
    var top = try run.tmp.dir.openDir(InitRun.io, ".", .{ .iterate = true });
    defer top.close(InitRun.io);
    var it = top.iterate();
    while (try it.next(InitRun.io)) |entry| {
        try std.testing.expect(
            std.mem.eql(u8, entry.name, "README.md") or
                std.mem.eql(u8, entry.name, "assets") or
                std.mem.eql(u8, entry.name, "data") or
                std.mem.eql(u8, entry.name, "src"),
        );
    }

    // A re-run on a healthy disk repairs the scaffold; README.md is kept.
    try run.run(&scaffold.dirs, &scaffold.files);
    for (scaffold.files) |f| try run.expectFile(f.path, f.content);
    try run.expectOut("kept     README.md (exists — init never overwrites)");
}

test "init: an init killed mid-write leaves the path absent, so re-init repairs it" {
    var run = InitRun.start();
    defer run.deinit();
    const alloc = run.arena_state.allocator();

    var env = std.process.Environ.Map.init(alloc);
    switch (@import("builtin").os.tag) {
        .windows => try env.putWindowsBlock(std.testing.environ.block.view()),
        else => try env.putPosixBlock(std.testing.environ.block.view()),
    }
    try env.put("DOGBED", try dogbedExe(alloc));

    // The issue's repro: ulimit -f kills the process with SIGXFSZ in the
    // middle of writing the 1356-byte README.md.
    const killed = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sh", "-c", "ulimit -f 1; exec \"$DOGBED\" init" },
        .cwd = .{ .dir = run.tmp.dir },
        .environ_map = &env,
    });
    try std.testing.expect(!killed.term.success());

    // The old code left a truncated README.md at the path that every later
    // init kept forever. Now the path is absent — or complete, never
    // partial — so the re-run repairs the scaffold.
    try std.testing.expectError(error.FileNotFound, run.readFile("README.md"));

    const repaired = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sh", "-c", "exec \"$DOGBED\" init" },
        .cwd = .{ .dir = run.tmp.dir },
        .environ_map = &env,
    });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, repaired.term);
    for (scaffold.files) |f| try run.expectFile(f.path, f.content);
    const build_sh = try run.tmp.dir.statFile(InitRun.io, "build.sh", .{});
    try std.testing.expect(@intFromEnum(build_sh.permissions) & 0o111 != 0);
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
        const data = "{\"body\":\"" ++ @as([1000]u8, @splat('&')) ++ "\"}";
        const trip = try renderBounded(alloc, template, data, profile, 4096, null, &.{}, &.{}, null);
        try std.testing.expectEqual(Trip.html_stage, trip);
    }
}

test "max-output: the html stage stops storing at the cap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, "{\"body\":\"" ++ @as([1000]u8, @splat('&')) ++ "\"}", .{});
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
            cli.wrapDocument(alloc, fragment, &@as([40]u8, @splat('&')), &.{}, &.{}, null, profile, 100),
        );
        // (b) repeated css entries
        const css8 = &@as([8][]const u8, @splat("a.css"));
        try std.testing.expectError(
            error.OutputLimitExceeded,
            cli.wrapDocument(alloc, fragment, null, css8, &.{}, null, profile, 100),
        );
        // (c) repeated head entries
        const head8 = &@as([8][]const u8, @splat("<meta property=\"og:title\" content=\"dogbed\">"));
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
        const data = "{\"title\":\"T & U\",\"body\":\"" ++ @as([200]u8, @splat('&')) ++ "\"}";
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
    const data = "{\"body\":\"" ++ @as([100000]u8, @splat('&')) ++ "\"}";
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
        cli.wrapDocument(alloc, "<p>hi</p>\n", &@as([100]u8, @splat('&')), &.{}, &.{}, null, .html, 50),
    );
}

// -- build scripts: failed rebuilds must not truncate pages (issue #15) --

/// A temp site scaffolded by `cli.scaffoldSite`, with helpers to run its
/// build.sh and inspect the site it produces. The tests below exercise the
/// actual build-script interface: `sh build.sh` with DOGBED pointing at the
/// real binary, exactly as a user would run it.
const BuildRun = struct {
    tmp: std.testing.TmpDir,
    arena_state: std.heap.ArenaAllocator,

    const io = std.testing.io;

    fn start() BuildRun {
        return .{
            .tmp = std.testing.tmpDir(.{}),
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
        };
    }

    fn deinit(self: *BuildRun) void {
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    /// Runs `cli.scaffoldSite` in this run's dir: the site skeleton,
    /// build.sh executable, the works.
    fn scaffoldSite(self: *BuildRun) !void {
        var out_buf = std.Io.Writer.Allocating.init(self.arena_state.allocator());
        var err_buf = std.Io.Writer.Allocating.init(self.arena_state.allocator());
        try cli.scaffoldSite(self.tmp.dir, std.testing.io, self.arena_state.allocator(), &out_buf.writer, &err_buf.writer, &scaffold.dirs, &scaffold.files);
    }

    /// Runs `sh build.sh` in the site with DOGBED set to `dogbed_value`,
    /// inheriting the rest of the environment (the script needs PATH for
    /// its external utilities).
    fn runBuild(self: *BuildRun, dogbed_value: []const u8) !std.process.RunResult {
        const alloc = self.arena_state.allocator();
        var env = std.process.Environ.Map.init(alloc);
        switch (@import("builtin").os.tag) {
            .windows => try env.putWindowsBlock(std.testing.environ.block.view()),
            else => try env.putPosixBlock(std.testing.environ.block.view()),
        }
        try env.put("DOGBED", dogbed_value);
        return std.process.run(alloc, std.testing.io, .{
            .argv = &.{ "sh", "build.sh" },
            .cwd = .{ .dir = self.tmp.dir },
            .environ_map = &env,
        });
    }

    fn readFile(self: *BuildRun, path: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(std.testing.io, path, self.arena_state.allocator(), .limited(1 << 20));
    }

    fn writeFile(self: *BuildRun, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    /// Fails the test if any entry in `dir` looks like a leftover temp file.
    fn expectNoTempFiles(self: *BuildRun, dir_path: []const u8) !void {
        var site = try self.tmp.dir.openDir(std.testing.io, dir_path, .{ .iterate = true });
        defer site.close(std.testing.io);
        var it = site.iterate();
        while (try it.next(std.testing.io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, "."));
            try std.testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
        }
    }

    fn expectExited(self: *BuildRun, result: std.process.RunResult, code: u8) !void {
        _ = self;
        try std.testing.expectEqual(std.process.Child.Term{ .exited = code }, result.term);
    }
};

test "build script: scaffold build renders every route, script executable" {
    var run = BuildRun.start();
    defer run.deinit();
    try run.scaffoldSite();

    const result = try run.runBuild(try dogbedExe(run.arena_state.allocator()));
    try run.expectExited(result, 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "rendered: index") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "rendered: about") != null);
    try std.testing.expect(std.mem.indexOf(u8, try run.readFile("site/index.html"), "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, try run.readFile("site/about.html"), "<h1") != null);
    try run.expectNoTempFiles("site");
}

test "build script: failed rebuild with malformed JSON leaves the page byte-identical" {
    var run = BuildRun.start();
    defer run.deinit();
    try run.scaffoldSite();
    const first = try run.runBuild(try dogbedExe(run.arena_state.allocator()));
    try run.expectExited(first, 0);
    const previous = try run.readFile("site/index.html");

    try run.writeFile("data/index.json", "{broken JSON\n");
    const failed = try run.runBuild(try dogbedExe(run.arena_state.allocator()));
    try run.expectExited(failed, 1);
    // stderr carries the diagnostic; nothing was installed.
    try std.testing.expect(std.mem.indexOf(u8, failed.stderr, "invalid JSON") != null);
    try std.testing.expectEqualStrings(previous, try run.readFile("site/index.html"));
    try run.expectNoTempFiles("site");
}

test "build script: failed rebuild with a malformed template leaves the page byte-identical" {
    var run = BuildRun.start();
    defer run.deinit();
    try run.scaffoldSite();
    const first = try run.runBuild(try dogbedExe(run.arena_state.allocator()));
    try run.expectExited(first, 0);
    const previous = try run.readFile("site/about.html");

    try run.writeFile("src/about.knap", "h1. broken\n{{ never_closed\n");
    const failed = try run.runBuild(try dogbedExe(run.arena_state.allocator()));
    try run.expectExited(failed, 1);
    try std.testing.expect(std.mem.indexOf(u8, failed.stderr, "template:") != null);
    try std.testing.expectEqualStrings(previous, try run.readFile("site/about.html"));
    try run.expectNoTempFiles("site");
}

test "build script: output-limit failure leaves the page byte-identical" {
    var run = BuildRun.start();
    defer run.deinit();
    try run.scaffoldSite();
    const first = try run.runBuild(try dogbedExe(run.arena_state.allocator()));
    try run.expectExited(first, 0);
    const previous = try run.readFile("site/index.html");

    // The output limit reaches the build script through its DOGBED
    // interface: a wrapper script that appends --max-output.
    const wrapper = try std.fmt.allocPrint(run.arena_state.allocator(), "#!/bin/sh\nexec \"{s}\" \"$@\" --max-output 200\n", .{try dogbedExe(run.arena_state.allocator())});
    try run.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "capped-dogbed", .data = wrapper, .flags = .{ .permissions = .executable_file } });
    const failed = try run.runBuild("./capped-dogbed");
    try run.expectExited(failed, 1);
    try std.testing.expect(std.mem.indexOf(u8, failed.stderr, "exceeded") != null or std.mem.indexOf(u8, failed.stderr, "exceeds") != null);
    try std.testing.expectEqualStrings(previous, try run.readFile("site/index.html"));
    try run.expectNoTempFiles("site");
}

test "build script: a first-time failed render does not install a partial page" {
    var run = BuildRun.start();
    defer run.deinit();
    try run.scaffoldSite();
    try run.writeFile("data/index.json", "{broken JSON\n");

    const failed = try run.runBuild(try dogbedExe(run.arena_state.allocator()));
    try run.expectExited(failed, 1);
    // The route that failed first has no page at all — not an empty file.
    try std.testing.expectError(error.FileNotFound, run.readFile("site/index.html"));
    try run.expectNoTempFiles("site");
}

test "init: the safe-output build.sh supersedes the v1 scaffold script, modified ones are kept" {
    const v1 = for (scaffold.files) |f| {
        if (std.mem.eql(u8, f.path, "build.sh")) break f;
    } else unreachable;
    const old_bytes = v1.supersedes.?;

    // An unmodified v1 build.sh is the scaffold's own file: archived, then
    // replaced by the safe-output script.
    var run = BuildRun.start();
    defer run.deinit();
    try run.tmp.dir.createDirPath(std.testing.io, "src");
    try run.writeFile("build.sh", old_bytes);
    var out_buf = std.Io.Writer.Allocating.init(run.arena_state.allocator());
    var err_buf = std.Io.Writer.Allocating.init(run.arena_state.allocator());
    try cli.scaffoldSite(run.tmp.dir, std.testing.io, run.arena_state.allocator(), &out_buf.writer, &err_buf.writer, &scaffold.dirs, &scaffold.files);
    try std.testing.expect(std.mem.indexOf(u8, out_buf.written(), "archived build.sh -> ") != null);
    try std.testing.expectEqualStrings(v1.content, try run.readFile("build.sh"));

    // A modified build.sh is the user's now: kept byte-identical.
    var run2 = BuildRun.start();
    defer run2.deinit();
    try run2.writeFile("build.sh", "#!/bin/sh\n# mine, not the scaffold's\n");
    var out2 = std.Io.Writer.Allocating.init(run2.arena_state.allocator());
    var err2 = std.Io.Writer.Allocating.init(run2.arena_state.allocator());
    try cli.scaffoldSite(run2.tmp.dir, std.testing.io, run2.arena_state.allocator(), &out2.writer, &err2.writer, &scaffold.dirs, &scaffold.files);
    try std.testing.expect(std.mem.indexOf(u8, out2.written(), "kept     build.sh (modified since it was scaffolded") != null);
    try std.testing.expectEqualStrings("#!/bin/sh\n# mine, not the scaffold's\n", try run2.readFile("build.sh"));
}

/// Copies `docs/src`, `docs/data`, and `docs/assets` from the repo into
/// `<tmp>/docs/`, plus build.sh itself, so the docs build can run in a
/// scratch site without touching the working tree.
fn copyDocsTree(run: *BuildRun) !void {
    const alloc = run.arena_state.allocator();
    const repo = std.Io.Dir.cwd();
    const subdirs = [_][]const u8{ "src", "data", "assets" };
    for (subdirs) |sub| {
        const src_path = try std.fmt.allocPrint(alloc, "{s}/docs/{s}", .{ build_options.repo_root, sub });
        var src = try repo.openDir(std.testing.io, src_path, .{ .iterate = true });
        defer src.close(std.testing.io);
        const dest_sub = try std.fmt.allocPrint(alloc, "docs/{s}", .{sub});
        try run.tmp.dir.createDirPath(std.testing.io, dest_sub);
        var it = src.iterate();
        while (try it.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            const src_file = try std.fmt.allocPrint(alloc, "docs/{s}/{s}", .{ sub, entry.name });
            const src_bytes = try repo.readFileAlloc(std.testing.io, src_file, alloc, .limited(16 * 1024 * 1024));
            const dest_file = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_sub, entry.name });
            try run.writeFile(dest_file, src_bytes);
        }
    }
    const script = try std.fmt.allocPrint(alloc, "{s}/docs/build.sh", .{build_options.repo_root});
    const script_bytes = try repo.readFileAlloc(std.testing.io, script, alloc, .limited(1 << 20));
    try run.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/build.sh", .data = script_bytes, .flags = .{ .permissions = .executable_file } });
}

test "docs build script: rebuilds the committed site byte-identically" {
    var run = BuildRun.start();
    defer run.deinit();
    try copyDocsTree(&run);

    // build.sh cds to the repo root relative to itself, so the script runs
    // from the tmp copy with DOGBED pointing at the fresh binary.
    const alloc = run.arena_state.allocator();
    var env = std.process.Environ.Map.init(alloc);
    switch (@import("builtin").os.tag) {
        .windows => try env.putWindowsBlock(std.testing.environ.block.view()),
        else => try env.putPosixBlock(std.testing.environ.block.view()),
    }
    try env.put("DOGBED", try dogbedExe(alloc));
    const result = try std.process.run(alloc, std.testing.io, .{
        .argv = &.{ "sh", "docs/build.sh" },
        .cwd = .{ .dir = run.tmp.dir },
        .environ_map = &env,
    });
    try run.expectExited(result, 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "rendered: index") != null);

    // Every committed page comes back byte-identical from the fresh build:
    // the safe-output script changed how pages land, not what they contain.
    const repo = std.Io.Dir.cwd();
    const site_path = try std.fmt.allocPrint(alloc, "{s}/docs/site", .{build_options.repo_root});
    var site = try repo.openDir(std.testing.io, site_path, .{ .iterate = true });
    defer site.close(std.testing.io);
    var it = site.iterate();
    var pages: usize = 0;
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html")) continue;
        const committed = try repo.readFileAlloc(std.testing.io, try std.fmt.allocPrint(alloc, "docs/site/{s}", .{entry.name}), alloc, .limited(4 * 1024 * 1024));
        const rebuilt = try run.readFile(try std.fmt.allocPrint(alloc, "docs/site/{s}", .{entry.name}));
        try std.testing.expectEqualStrings(committed, rebuilt);
        pages += 1;
    }
    try std.testing.expect(pages >= 6);
    try run.expectNoTempFiles("docs/site");
}
