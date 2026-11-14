# Research Papers

LaTeX research papers built with [Zig](https://ziglang.org) as the build
system — no Makefiles, no shell scripts. The build script discovers papers,
renders them to PDF with `latexmk`, and installs the results to `zig-out/`.

## Requirements

- [Zig](https://ziglang.org/download/) 0.17.1
- A TeX distribution with the following on `PATH`:

  | Tool       | Provided by                          |
  |------------|--------------------------------------|
  | `latexmk`  | texlive-latex-extra / latexmk        |
  | `pdflatex` | any TeX Live / MiKTeX installation   |
  | `install`  | GNU coreutils (`--compare` required) |

  On Debian/Ubuntu: `sudo apt install texlive-latex-extra latexmk`

The build checks for all required tools up front and fails with a clear
message if anything is missing. It never installs anything itself.

## Usage

```sh
zig build example-paper        # render one paper  -> zig-out/example-paper.pdf
zig build                # render all papers -> zig-out/*.pdf
zig build papers         # same as the default target
```

Other useful flags:

```sh
zig build example-paper --prefix /some/dir   # install elsewhere instead of zig-out/
zig build example-paper --verbose            # show the underlying commands
```

## Repository layout

```
build.zig              build system (no external scripts)
papers/
  example-paper/
    main.tex           document shell: TOC, LOF, \input of sections
    style/
      paper.sty        all styling for the paper
    sections/
      introduction.tex
      method.tex
      results.tex
zig-out/               rendered PDFs (gitignored)
.zig-cache/            build cache, incl. LaTeX intermediates (gitignored)
```

## How the build works

For each paper, `build.zig` wires up a small pipeline of standard build
steps:

1. **Copy sources into the cache.** The paper's directory is copied into
   `.zig-cache` via a `WriteFile` step. Every `.tex`/`.sty` file becomes a
   tracked input, so editing any source file triggers a rebuild of that
   paper only — and `latexmk` never writes intermediates into your source
   tree.
2. **Render.** A `Run` step invokes `latexmk -pdf` inside the copied
   directory with a generated output directory. latexmk reruns pdflatex as
   many times as needed for the table of contents, list of figures, and
   cross-references to stabilise (the "double render"), and the build
   system caches the result.
3. **Install.** A side-effecting `Run` step runs
   `install -D -C -m 644` to place the PDF at `<prefix>/<name>.pdf`
   (`zig-out/<name>.pdf` by default). It always executes, so deleting
   `zig-out` and rebuilding restores the PDFs even when the (cached) render
   is a no-op; `-C` skips the copy when the installed file is already
   current.

Tool checks happen at configure time: if `latexmk`, `pdflatex`, or GNU
`install` are missing, the build fails immediately with install hints.

### Error reporting

pdflatex reports errors on stdout, which the build system does not display
when a step fails. The custom `-pdflatex` rule passed to latexmk redirects
pdflatex's output to stderr, so a failed build prints the actual LaTeX
errors (`! Undefined control sequence`, the offending line, etc.) while
successful builds stay quiet.

## Adding a new paper

Create a directory under `papers/` containing a `main.tex`:

```
papers/my-paper/
├── main.tex
├── style/
│   └── my-paper.sty     (optional — or reuse another paper's style)
└── sections/
    └── ...
```

That's it. Papers are auto-discovered at configure time (any subdirectory
of `papers/` containing `main.tex`), so a new step appears with no changes
to `build.zig`:

```sh
zig build my-paper      # -> zig-out/my-paper.pdf
```

Conventions for `main.tex`:

- Keep all styling in a separate `.sty` file (e.g.
  `\usepackage{style/my-paper}`) so papers can share or fork styles.
- Import section files with `\input{sections/...}`.
- The rendered PDF is named after the paper directory, not the tex file.
- Everything in the paper directory is copied to the build cache and
  treated as a build input — only `.tex`/`.sty`/figures need to live there.

## Troubleshooting

- **A build wedged in a weird state** (corrupt LaTeX artifacts, etc.):
  `rm -rf .zig-cache zig-out` and rebuild.
- **Missing packages at render time** (`! LaTeX Error: File ... not found`):
  install the corresponding texlive package for whatever macro is failing;
  the error text from the build will name it.
