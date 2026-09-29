//! dogbed test suite: the pipeline is the product, so the smoke test runs
//! the whole thing — Knap template + JSON --k4o--> Textile --oliver--> HTML.

const std = @import("std");
const kt = @import("k4o");
const oliver = @import("oliver");

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
