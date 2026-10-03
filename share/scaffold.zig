//! Embedded `dogbed init` scaffold: a minimal but complete site — routes,
//! layout, content dirs, and the knap->oliver->HTML wiring — so an agent or
//! human starts from a working skeleton instead of a blank dir. The shape
//! mirrors dogbed's own dogfooded docs site (docs/src + docs/data +
//! docs/build.sh -> docs/site): one Knap template per route, one JSON object
//! per route, and a shell script that walks the route table.
//!
//! The poop rules (shared with `k4o init`, load-bearing):
//!  - Only create files that don't exist. Never overwrite an existing file,
//!    modified or not. Existence is the only test: no manifests, no
//!    checksums, no "was it modified" detective work. init is strictly
//!    additive, forever.
//!  - When a scaffold entry supersedes an older one — a future dogbed ships
//!    new content for a path this scaffold also writes — the old file is
//!    archived to a timestamped dir and the location is reported, not
//!    deleted. Bagged, not curbed; no trash day, no auto-expiry.

pub const File = struct {
    path: []const u8,
    content: []const u8,
    executable: bool = false,
    /// Byte content of the previous scaffold version's file at this path.
    /// When init finds an existing file whose bytes match exactly, it is the
    /// old scaffold's file: archive it, then write the new content. Anything
    /// else at the path is the user's now — kept untouched. v1 supersedes
    /// nothing; the mechanism is here, tested, for the first change that
    /// needs it.
    supersedes: ?[]const u8 = null,
};

pub const dirs = [_][]const u8{ "assets", "data", "src" };

pub const files = [_]File{
    .{ .path = "README.md", .content = @embedFile("scaffold/README.md") },
    .{ .path = "routes.txt", .content = @embedFile("scaffold/routes.txt") },
    .{ .path = "build.sh", .content = @embedFile("scaffold/build.sh"), .executable = true },
    .{ .path = "assets/style.css", .content = @embedFile("scaffold/assets/style.css") },
    .{ .path = "data/about.json", .content = @embedFile("scaffold/data/about.json") },
    .{ .path = "data/index.json", .content = @embedFile("scaffold/data/index.json") },
    .{ .path = "src/about.knap", .content = @embedFile("scaffold/src/about.knap") },
    .{ .path = "src/index.knap", .content = @embedFile("scaffold/src/index.knap") },
    .{ .path = "src/layout.knap", .content = @embedFile("scaffold/src/layout.knap") },
};

pub const archive_dirname = ".dogbed-archive";
