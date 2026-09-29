//! Embedded starter templates. `dogbed template <name>` prints one to stdout
//! so the user copies it and owns it — no discovery paths, no versioning, no
//! fetching. Three starters, done. Each ships matching example data that the
//! render tests push through the full pipeline.

pub const Entry = struct {
    name: []const u8,
    description: []const u8,
    template: []const u8,
    example_data: []const u8,
};

pub const entries = [_]Entry{
    .{
        .name = "verdict",
        .description = "PR review verdict: blockers, nits, summary.",
        .template = @embedFile("verdict.knap"),
        .example_data = @embedFile("verdict.json"),
    },
    .{
        .name = "release-notes",
        .description = "Release notes: highlights, breaking, added, changed, fixed.",
        .template = @embedFile("release-notes.knap"),
        .example_data = @embedFile("release-notes.json"),
    },
    .{
        .name = "reading-note",
        .description = "Reading note: author, rating, quote, notes.",
        .template = @embedFile("reading-note.knap"),
        .example_data = @embedFile("reading-note.json"),
    },
};
