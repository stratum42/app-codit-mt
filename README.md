# App::Codit::MT

A multi-threaded Perl/Tk MDI code editor built on `Tcl::Tk::MT` and a pure-C11 XS core (`App::Codit::MT::Core`).

`App::Codit::MT` owes its layout, plugin model, and spirit to Hans Jeuken's [App::Codit](https://metacpan.org/pod/App::Codit) and [Tk::CodeText](https://metacpan.org/pod/Tk::CodeText). Where `App::Codit` builds directly on Perl/Tk widgets, this experiment keeps the familiar MDI shell and plugin hooks while moving text storage, incremental syntax lexing, directory search, minimap rasterization, and visible-line viewport drawing into a C11 XS core and `Tcl::Tk::MT`'s canvas pipeline (Metal on macOS, Vulkan on Linux/Windows, with a Software CPU fallback).

---

## Architecture

```
+-----------------------------------------------------------------------+
|  App::Codit::MT  (MDI Shell, Menu/Toolbar, Locked Status Bar)         |
|  +---------------+-------------------------------+-----------------+  |
|  | Left Dock     | Center MDI Notebook           | Right Panel     |  |
|  |  - Files      |  - Document (PieceTable +     |  - GPU Minimap  |  |
|  |  - Outline    |    Incremental Syntax Lexer)  |    (RGBA8888)   |  |
|  |  - Git        |  - CodeView::GPU (Metal/Vk)   |                 |  |
|  |  - Bookmarks  |    or CodeView::TkText (live) |                 |  |
|  +---------------+-------------------------------+-----------------+  |
|  | Bottom Dock: Search & Replace | Console (F5) | Git Diff            |
|  +--------------------------------------------------------------------+
|  App::Codit::MT::Core (Pure C11 Tier-1 XS, PERL_XS_THREADSAFE)        |
|   - PieceTable (zero-copy mmap + line index + undo/redo)              |
|   - Incremental Lexer (perl, c, tcl, python, json, shell, md, text)   |
|   - Parallel Directory Search (pthreads / Win32 threads)              |
|   - Minimap RGBA8888 Renderer (zero-copy packed MT::Array U8)         |
+-----------------------------------------------------------------------+
```

### Components

- **`App::Codit::MT::Core`** (`Core.xs`, `c/*.c`): Pure C11 Tier-1 thread-safe XS module (`PERL_NO_GET_CONTEXT` + `PERL_XS_THREADSAFE`), building on both `perl5-mt` and stock Perl 5.
  - **Piece Table**: `mmap` / `MapViewOfFile` file loading, append-only edit buffer, `memchr` line-start index, and an undo/redo stack.
  - **Incremental Syntax Lexer**: Per-line state machine tracking multi-line constructs (C block comments, Perl POD `=head..=cut`, Python triple-quoted strings, Markdown fences) so edits only re-lex until `end_state` stabilizes.
  - **Multi-Threaded Search**: Parallel workspace search honoring `PERL_FORCE_SCALAR=1` for deterministic single-threaded parity.
  - **Minimap Renderer**: Rasterizes a syntax-colored minimap into a packed `U8` RGBA8888 buffer for direct upload to `Tcl::Tk::MT::Photo`.
- **`App::Codit::MT::Document`** and **`CodeView::{GPU,TkText}`**:
  - `CodeView::GPU` draws only the visible rows (`[top_line .. top_line + visible_rows]`) in a single `Tcl::Tk::MT::Canvas::batch` call, so per-frame draw work scales with viewport height rather than total file length.
  - `CodeView::TkText` implements the same viewport interface on a native Tk `text` widget, allowing live engine toggling (`GPU` / `TkText`) and side-by-side comparison.
- **`App::Codit::MT::Plugin`**: Minimal lifecycle hook base class (`init`, `on_doc_open`, `on_doc_switch`, `on_doc_save`, `on_doc_change`, `on_cursor`, `on_scroll`, `on_doc_close`, `shutdown`).

---

## Built-in Plugins

| Plugin | Dock | Summary |
|---|---|---|
| **FileBrowser** | Left | Lazy-expanding workspace `ttk::treeview`, live filename filter, double-click to open |
| **PerlSubs** | Left | Symbol outline (`package`/`sub` for Perl, function definitions for C/H/XS) with click-to-jump |
| **Git** | Left + Bottom | Non-blocking branch indicator, changed files list, inline gutter diff markers (`add`/`mod`/`del`), diff viewer |
| **Bookmarks** | Left | Toggle line bookmarks (`Cmd/Ctrl+B`), gutter dots, cross-document jump list |
| **SearchReplace** | Bottom | In-file Find/Replace (literal, case-insensitive, regex) and multi-threaded project search (`Core::search_dir`) |
| **Console** | Bottom | Non-blocking command runner and `Run Current File (F5)` output pane |
| **Minimap** | Right | Syntax-colored minimap with click/drag viewport scrubbing |

---

## Building & Running

### Prerequisites

- Perl 5.16+ (tested primarily on `perl5-mt` 5.40.2 and recent stock Perl 5)
- A C11 compiler (`clang`, `gcc`, or MinGW-w64 UCRT64 on Windows)
- `Tcl::Tk::MT` installed in `@INC`, pointed to via `TCL_TK_MT_DIR`, or built in a sibling `../tcl-tk-mt` checkout

### macOS (Apple Silicon / Intel)

```sh
perl Makefile.PL
make -j
prove -b -v t/

# Launch interactive editor (Metal GPU backend by default)
./bin/codit-mt /path/to/workspace
```

### Linux (x86_64 / arm64)

```sh
# Ensure Tcl/Tk 8.6+ or 9.x and Vulkan drivers are installed for Tcl::Tk::MT
perl Makefile.PL
make -j
prove -b -v t/

# Launch with Vulkan (auto) or Software fallback
./bin/codit-mt --backend=auto /path/to/workspace
```

### Windows (Win64 / MSYS2 UCRT64)

```sh
perl Makefile.PL
gmake -j
prove -b -v t/

perl bin/codit-mt --backend=auto C:\path\to\workspace
```

---

## CLI Options

```
codit-mt [options] [files_or_dir...]

  --engine=gpu|tktext               Editor viewport engine (default: gpu)
  --backend=auto|metal|vulkan|software|off
                                    GPU rendering backend (default: auto)
  --workspace=DIR                   Workspace root directory
  --auto-exit-ms=N                  Auto-exit GUI after N milliseconds
  --headless                        Run without an interactive window
  --bench-file=PATH                 File to open and scroll in headless mode
  --frames=N                        Frames to render in headless mode (default: 120)
  --json                            Output headless benchmark metrics as JSON
```

---

## Status & Limitations

`App::Codit::MT` is an early, working prototype rather than a drop-in replacement for the full `App::Codit` distribution:

- **Unicode and editing ergonomics**: Piece-table offsets and column calculations are currently byte-oriented. ASCII and single-byte text work reliably, while multi-byte UTF-8, combining marks, wide glyphs, and soft line-wrapping still need work.
- **Syntax highlighting**: The built-in C lexer covers 8 languages (`perl`, `c`, `tcl`, `python`, `json`, `shell`, `markdown`, `text`) with a lightweight line state machine. It is intentionally simple and does not attempt full Perl parsing (e.g., complex quoting operators or nested heredocs).
- **Plugin coverage**: Seven built-in plugins are included. Many features and plugins from upstream `App::Codit` (such as session management, snippets, spell checking, or external formatter integration) are not yet ported.
- **Platform maturity**: Most interactive testing so far has been on macOS (Metal and Software backends). Linux (Vulkan) and Windows (Win64/MSYS2) paths are wired up and compile, but have seen less day-to-day testing.

---

## Sample Measurements

A self-contained benchmark script is included so you can measure on your own machine:

```sh
perl -Iblib/lib -Iblib/arch bench/codit_bench.pl
```

Numbers below are sample measurements from one machine (`perl5-mt` 5.40.2, Apple Silicon macOS, synthetic 500,000-line / 24.71 MB Perl file, 1000x700 headless viewport). Your results will vary with CPU, OS, GPU/driver, disk cache state, and file structure.

| Benchmark | Sample Measurement |
|---|---|
| Cold startup (headless + 7 plugins) | 83.96 ms (RSS 37.92 MB) |
| 500,000-line Perl file open: `PieceTable` (`mmap` + line index) | 6.32 ms |
| 500,000-line Perl file open: Native `Tk::Text` load | 226.64 ms |
| 500,000-line smooth scroll: `CodeView::GPU` (Metal, 1000x700) | 162.9 FPS (p50 6.144 ms, p95 6.483 ms) |
| 500,000-line smooth scroll: `CodeView::GPU` (Software, 1000x700) | 155.3 FPS (p50 6.437 ms, p95 6.774 ms) |
| 500,000-line smooth scroll: `CodeView::TkText` (1000x700) | 146.9 FPS (p50 6.867 ms, p95 7.154 ms) |
| Incremental typing at line 250,000: Core edit + incremental lex | p50 0.089 ms, p95 0.108 ms |
| Incremental typing at line 250,000: Edit + lex + Metal frame | p50 9.234 ms, p95 9.703 ms |
| Project search (`perl5-mt` tree, `Perl_croak`, 1,867 matches): `Core::search_dir` (MT) | 132.16 ms |
| Project search: `Core::search_dir` (`PERL_FORCE_SCALAR=1`) | 258.47 ms |
| Project search: Pure-Perl recursive grep | 1179.38 ms |

---

## Acknowledgments & License

With sincere thanks to:

- **Hans Jeuken**, for creating [App::Codit](https://metacpan.org/pod/App::Codit) and [Tk::CodeText](https://metacpan.org/pod/Tk::CodeText), whose design and plugin architecture inspired this work.
- **Vadim Konovalov** and the contributors to [Tcl::Tk](https://metacpan.org/pod/Tcl::Tk), as well as the **Tcl/Tk** developers, for keeping Tk portable and approachable from Perl.
- The **Perl 5** community and CPAN maintainers, whose tools and decades of careful engineering make projects like this possible.

This software is free software; you can redistribute it and/or modify it under the same terms as Perl itself (the Artistic License or the GNU General Public License). See `LICENSE` for details.
