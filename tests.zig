//! dogbed test suite: the pipeline is the product, so the smoke test runs
//! the whole thing — Knap template + JSON --k4o--> Textile --oliver--> HTML.

const std = @import("std");
const kt = @import("k4o");
const oliver = @import("oliver");
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
    const out = try cli.wrapDocument(alloc, fragment, null, &.{}, .html);
    try std.testing.expectEqualStrings(fragment, out);
}

test "shell: title wraps the fragment and escapes the title" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const out = try cli.wrapDocument(alloc, "<p>hi</p>\n", "Art & \"<b>Science</b>\"", &.{}, .html);
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

    const one = try cli.wrapDocument(alloc, "<p>hi</p>\n", null, &.{"a.css"}, .html);
    try std.testing.expect(std.mem.indexOf(u8, one, "<title") == null);
    try std.testing.expect(std.mem.indexOf(u8, one, "<link rel=\"stylesheet\" href=\"a.css\">") != null);

    const two = try cli.wrapDocument(alloc, "<p>hi</p>\n", null, &.{ "a.css", "b.css" }, .html);
    try std.testing.expect(std.mem.indexOf(u8, two, "<title") == null);
    const a = std.mem.indexOf(u8, two, "href=\"a.css\"").?;
    const b = std.mem.indexOf(u8, two, "href=\"b.css\"").?;
    try std.testing.expect(a < b);
}

test "shell: xhtml profile emits the XHTML 1.0 Strict shell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const out = try cli.wrapDocument(alloc, "<p>hi</p>\n", "T", &.{"c.css"}, .xhtml);
    try std.testing.expect(std.mem.startsWith(u8, out, "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">"));
    try std.testing.expect(std.mem.indexOf(u8, out, "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<meta charset") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<link rel=\"stylesheet\" href=\"c.css\" />") != null);
}

test "shell: fragment without a trailing newline still lands on its own body line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const out = try cli.wrapDocument(alloc, "<p>hi</p>", "T", &.{}, .html);
    try std.testing.expect(std.mem.indexOf(u8, out, "<p>hi</p>\n</body>") != null);
}
