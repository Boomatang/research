const std = @import("std");

/// Tools that must be present on PATH to render papers. `install` must be
/// the GNU coreutils version (it needs the --compare and -D options).
const required_tools = [_][]const u8{
    "latexmk",
    "pdflatex",
    "install",
};

/// Directory that papers are discovered in, relative to the build root.
const papers_dir = "papers";

pub fn build(b: *std.Build) void {
    checkTools(b);

    const paper_names = discoverPapers(b) catch |err| {
        std.debug.print("error: failed to scan '{s}' for papers: {s}\n", .{
            papers_dir, @errorName(err),
        });
        std.process.exit(1);
    };

    if (paper_names.len == 0) {
        std.debug.print("error: no papers found under '{s}/' (expected subdirectories containing main.tex)\n", .{papers_dir});
        std.process.exit(1);
    }

    // Default `zig build` target: build every discovered paper.
    const all = b.step("papers", "Build all papers");

    for (paper_names) |name| {
        const install = addPaper(b, name);

        // `zig build <paper-name>`
        const paper_step = b.step(name, b.fmt("Build the paper '{s}' to zig-out/{s}.pdf", .{ name, name }));
        paper_step.dependOn(&install.step);

        // `zig build` (default) and `zig build papers`.
        all.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }
}

/// Wires one paper into the build graph.
///
/// The paper's source directory is copied into the Zig cache (so latexmk
/// never writes intermediates into the source tree), rendered with latexmk
/// into a generated output directory, and the resulting PDF is installed to
/// `zig-out/<name>.pdf`.
///
/// latexmk performs as many passes as needed for the table of contents,
/// list of figures, and cross-references to stabilise.
fn addPaper(b: *std.Build, name: []const u8) *std.Build.Step.Run {
    const src_dir = b.path(b.fmt("{s}/{s}", .{ papers_dir, name }));

    // Copy the paper's sources to a generated directory in the Zig cache.
    // The copy tracks every source file as an input, so editing any
    // .tex/.sty file invalidates the cache and triggers a rebuild.
    const wf = b.addWriteFiles();
    const workdir = wf.addCopyDirectory(src_dir, ".", .{});

    // The title-page date comes from git, not \today: the last commit that
    // touched this paper, or today's date when the paper has uncommitted
    // changes (marked as such on the title page).
    _ = wf.add("gitdate.tex", gitDateFile(b, paperGitDate(b, name)));

    // Render the paper. latexmk reruns pdflatex until the TOC/LOF and
    // cross-references settle, so the double render is handled for us.
    //
    // pdflatex reports errors on stdout, which the build system does not
    // surface when a step fails. The custom -pdflatex rule below redirects
    // pdflatex's output to stderr inside latexmk's own command invocation,
    // so failures print the actual LaTeX errors while successful builds
    // stay quiet (the captured output is only shown on failure).
    const run = b.addSystemCommand(&.{"latexmk"});
    run.setName(b.fmt("latexmk ({s})", .{name}));
    run.setCwd(workdir);
    run.addArgs(&.{
        "-pdf",
        "-halt-on-error",
        "-pdflatex=pdflatex -interaction=nonstopmode %O %S 1>&2",
        "main.tex",
    });
    const out_dir = run.addPrefixedOutputDirectoryArg("-outdir=", "out");
    _ = run.captureStdErr(.{ .basename = "latexmk.log" });

    // latexmk names the PDF after the job name (main.tex -> main.pdf).
    const pdf = out_dir.path(b, "main.pdf");

    // Install to <prefix>/<name>.pdf (zig-out by default).
    //
    // A plain InstallFile step can be skipped entirely by the build system
    // when everything upstream is a cache hit, which leaves zig-out empty
    // after a manual `rm -rf zig-out`. A side-effecting Run step always
    // executes, so it restores missing files. `install --compare` skips the
    // copy when the installed file is already current, and `-D` creates
    // missing directories. The destination is passed as a directory-style
    // path argument so it is resolved at make time, honoring
    // `zig build --prefix`.
    const install = b.addSystemCommand(&.{"install"});
    install.setName(b.fmt("install {s}.pdf", .{name}));
    install.stdio = .inherit; // side-effecting: always run
    install.addArgs(&.{ "-D", "-C", "-m", "644" });
    install.addFileArg(pdf);
    install.addDirectoryArg(.{ .relative = .{
        .base = .install_prefix,
        .sub_path = b.fmt("{s}.pdf", .{name}),
    } });
    return install;
}

/// Verifies that every required tool is on PATH. Never installs anything;
/// on failure, prints what is missing and how to get it, then exits.
fn checkTools(b: *std.Build) void {
    var missing: [required_tools.len][]const u8 = undefined;
    var missing_count: usize = 0;

    for (required_tools) |tool| {
        if (b.findProgram(.{ .names = &.{tool} }) == null) {
            missing[missing_count] = tool;
            missing_count += 1;
        }
    }

    if (missing_count == 0) return;

    std.debug.print(
        \\error: missing required tool{s} for building papers:
        \\
    , .{if (missing_count == 1) "" else "s"});
    for (missing[0..missing_count]) |tool| {
        std.debug.print("  - {s}\n", .{tool});
    }
    std.debug.print(
        \\
        \\These must be installed manually before building.
        \\On Debian/Ubuntu:  sudo apt install texlive-latex-extra latexmk
        \\On Fedora:         sudo dnf install texlive-latexmk texlive-collection-latexextra
        \\On Arch:           sudo pacman -S texlive-basic texlive-latexextra
        \\
    , .{});
    std.process.exit(1);
}

/// Discovers papers: every subdirectory of `papers/` containing a main.tex.
fn discoverPapers(b: *std.Build) ![][]const u8 {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    var names: std.ArrayList([]const u8) = .empty;

    var dir = cwd.openDir(io, papers_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names.toOwnedSlice(b.allocator),
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| return err) |entry| {
        if (entry.kind != .directory) continue;
        // Hidden directories (e.g. .git) are not papers.
        if (entry.name.len > 0 and entry.name[0] == '.') continue;

        const sub = dir.openDir(io, entry.name, .{}) catch continue;
        defer sub.close(io);
        sub.access(io, "main.tex", .{}) catch continue;

        try names.append(b.allocator, try b.allocator.dupe(u8, entry.name));
    }

    const result = try names.toOwnedSlice(b.allocator);
    std.mem.sort([]const u8, result, {}, struct {
        fn lessThan(_: void, a: []const u8, c: []const u8) bool {
            return std.mem.lessThan(u8, a, c);
        }
    }.lessThan);
    return result;
}

/// Title-page date information derived from git for one paper.
const GitDate = struct {
    /// ISO 8601 (YYYY-MM-DD), formatted for display with `formatLongDate`.
    iso: []const u8,
    /// True when the paper has uncommitted (including untracked) changes.
    dirty: bool,
};

/// Derives the title-page date for a paper from git.
///
/// Clean tree: the committer date of the last commit touching the paper.
/// Dirty tree: today's date. Any failure (git missing, not a repo, no
/// history) falls back to today's date so the build never breaks.
fn paperGitDate(b: *std.Build, name: []const u8) GitDate {
    const alloc = b.allocator;
    const io = b.graph.io;
    const dir_arg = b.fmt("{s}/{s}", .{ papers_dir, name });

    const today = todayIso(alloc, io) orelse
        return .{ .iso = "1970-01-01", .dirty = false };

    // Uncommitted or untracked changes count as a change: show today.
    const status = std.process.run(alloc, io, .{
        .argv = &.{ "git", "status", "--porcelain", "--", dir_arg },
    }) catch return .{ .iso = today, .dirty = false };
    if (!status.term.success()) return .{ .iso = today, .dirty = false };
    if (status.stdout.len != 0) return .{ .iso = today, .dirty = true };

    // Clean: last commit that touched anything in the paper directory.
    const log = std.process.run(alloc, io, .{
        .argv = &.{ "git", "log", "-1", "--format=%cs", "--", dir_arg },
    }) catch return .{ .iso = today, .dirty = false };
    if (!log.term.success()) return .{ .iso = today, .dirty = false };

    const iso = std.mem.trim(u8, log.stdout, " \n\r\t");
    if (iso.len == 0) return .{ .iso = today, .dirty = false };
    return .{ .iso = iso, .dirty = false };
}

/// Runs `date +%F` to get today's date in ISO form (local timezone, matching
/// git's committer-date behaviour). Returns null if the command fails.
fn todayIso(alloc: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "date", "+%F" },
    }) catch return null;
    if (!res.term.success()) return null;
    const trimmed = std.mem.trim(u8, res.stdout, " \n\r\t");
    if (trimmed.len == 0) return null;
    return trimmed;
}

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

/// Converts an ISO date (YYYY-MM-DD) to long form, e.g. "15 November 2026".
/// Returns null when the input is not a well-formed ISO date.
fn formatLongDate(alloc: std.mem.Allocator, iso: []const u8) ?[]const u8 {
    if (iso.len != 10 or iso[4] != '-' or iso[7] != '-') return null;

    const year = std.fmt.parseInt(u16, iso[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, iso[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, iso[8..10], 10) catch return null;
    if (month < 1 or month > 12) return null;

    return std.fmt.allocPrint(alloc, "{d} {s} {d}", .{
        day, month_names[month - 1], year,
    }) catch null;
}

/// Builds the contents of the generated `gitdate.tex` for a paper. The file
/// is `\input` by main.tex and overrides `\date`. When the paper has
/// uncommitted changes, a small note is appended beneath the date.
fn gitDateFile(b: *std.Build, git_date: GitDate) []const u8 {
    const long = formatLongDate(b.allocator, git_date.iso) orelse "1 January 1970";

    const dirty_suffix: []const u8 = if (git_date.dirty)
        "\\\\[4pt]{\\small\\itshape (uncommitted changes)}"
    else
        "";

    return std.mem.concat(b.allocator, u8, &.{
        "% Generated by build.zig from git metadata. Do not edit.\n",
        "\\date{",
        long,
        dirty_suffix,
        "}\n",
    }) catch "unreachable";
}
