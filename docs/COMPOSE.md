# Compose

Compose (`run compose [name]`, src/user/compose.asm) is one program for
documents, slides and spreadsheets. A document is one list of blocks, and
there are three views of it:

- **Pages**: rich text flowed onto 8.5 by 11 inch pages. It has headings,
  bold, italic, underline, struck-through text, bulleted and numbered lists,
  tables and images.
- **Slides**: the same blocks on 16:9 slides. A sidebar shows a thumbnail of
  each one, and F5 presents them. A slide is laid out 960 by 540 points and
  shown as large as the window allows, in steps of a quarter pixel a point.
- **Grid**: a spreadsheet of the grid the cursor is on. It holds numbers,
  text and formulas, and works them out again by what depends on what.

A table on a page is a grid. The Grid view shows all of it, and the page
shows the rows and columns of its table. A slide frame on a page shows as a
small slide card, and a grid inside a slide shows as a table on it.

## Blocks

| kind | what it is |
|---|---|
| text, heading 1-3 | a paragraph of UTF-8 text, with attributes for each byte |
| bullet, number | a list item; numbered items in a row count up together |
| grid | 200 rows by 26 columns of cells; its text is its name ("Grid 1") |
| image | B,G,R pixels, 1024 by 1024 at most; its text is its caption |
| slide | a slide frame: its text is the slide's title, and it holds the blocks after it (`kids`) |

Slides are built from the blocks:

- Each frame is one slide.
- Outside frames, each Heading 1 starts a slide that holds everything up to
  the next one.
- A slide with no title is dropped if it holds nothing but empty text.
- A title followed by nothing, or by a single paragraph, is laid out centred,
  as a title slide.

Frames are never nested.

## Formulas

A cell is a formula when it starts with `=`. Otherwise it is a number if it
reads as one (`12`, `-3.5`, `1e3`, `15%`), and text if not.

- **Operators:** `+ - * /`, unary `-`, `&` (joins text), and comparisons
  `= <> < <= > >=`.
- **References and ranges:** `A1`, `$B$2`, `A1:C3`.
- **Functions:** `SUM`, `AVERAGE`, `MIN`, `MAX`, `COUNT`, `IF`, `ABS`,
  `ROUND`, `TRUE`, `FALSE`.
- **Errors:** `#DIV/0!`, `#VALUE!`, `#REF!`, `#NAME?`, `#CYCLE!`, `#SYNTAX!`
  and `#NUM!`. An error in a cell spreads to the cells that use it.

When a cell changes, it and every cell that depends on it are marked, and
only those are worked out again, depth first. A cycle is caught as it is
found. The work runs on a stack of its own, 8 MiB, so a chain 200 cells
long is fine.

## Keys

| key | does |
|---|---|
| F1 / F2 / F3 | Pages / Slides / Grid |
| F5 | present, from the slide shown; →, Space, Enter, PgDn: next; ←, Backspace, PgUp: back; Home, End; Esc ends |
| ctrl+B, ctrl+I (or ctrl+E), ctrl+U, ctrl+D | bold, italic, underline, struck through |
| ctrl+N | text → heading 1 → 2 → 3 → text |
| ctrl+L | text → bulleted → numbered → text |
| ctrl+T | a table here (on the Grid view: a new grid at the end) |
| ctrl+K | a slide frame (on Slides: after the slide shown) |
| ctrl+G | an image (a landscape to start with) |
| ctrl+R, ctrl+_ | another row, another column in the grid |
| ctrl+Z, ctrl+Y | undo, redo (typing in one block is one change; 100 kept) |
| ctrl+A, ctrl+C, ctrl+X, ctrl+V | everything, copy, cut, paste (inside compose) |
| ctrl+S | save into the store, and commit |
| F7 | the paper: as the desktop's theme is, or light; the Light paper button too |
| F9, F10 | export NAME.txt, NAME.csv (the cursor's grid, or the first one) |
| F12 | the document, block by block, on the console |
| ctrl+Q, ctrl+W | close |

On a grid:

- Typing replaces the cell, and Enter edits what is already in it.
- Enter commits and moves down. Tab commits and moves right; past a table's
  last cell on a page, Tab adds a row. Esc cancels the edit.

Shift with the arrows, Home or End selects. The mouse places the cursor and
dragging selects. The toolbar has the views,
the styles, the inserts, Present and Save. In the Grid view you can click a
cell, the formula bar, or a grid's tab. The wheel scrolls.

## Light and dark

Compose's window is drawn with the desktop's kit (src/user/kit.inc): its
toolbar, buttons, fields, sidebar and status line take the desktop's look,
its colours, accent, fonts and scale, and follow it as it changes (WE_LOOK,
`settings set display.theme light`).

The paper (pages, slides, the presenter and the grid's cells) is the
document's own setting. F7, or the Light paper button left of Present,
switches it between:

- **Auto**: the paper is as the desktop's theme is, dark in the dark;
- **Light paper**: white pages and slides, whatever the theme is.

The choice is kept in the store as `compose/theme` (`auto` or `light`), so
the next document opens the same way.

The window is 1040 by 600 points to start with and may be resized. Compose
lays everything out in points; the desktop's scale (two pixels a point on a
2560 by 1600 screen) turns them into pixels.

## Files

Documents are kept in the store, through compose's store capability, which
reaches only the names under `compose/`. `compose report` opens
`compose/report.axd`, or starts a new document of that name. `compose
notes.txt` and `compose data.csv` import plain text and CSV.

Plain text import reads:

- `# `, `## ` and `### ` as headings;
- `- ` and `* ` as bullets;
- `1. ` as numbered items;
- lines with tabs in them, or starting with `|`, as the rows of a grid (a
  `|---|` rule under a header is skipped).

Each save is a commit, with the message `compose: NAME`. A blob is 1 MiB at
most.

### The format (.axd)

The file starts with `AXDC`, then the version as a u16 (1), then the flags as
a u16 (0).

The rest is records. Each record is:

1. a tag byte;
2. its payload's length, as LEB128;
3. the payload.

Numbers inside payloads are unsigned LEB128 too (`var` below). A reader skips
tags it does not know, so newer writers can add records. A version newer
than the reader's is refused.

| tag | record | payload |
|---|---|---|
| 0 | end | (length 0) last |
| 1 | text | kind byte (0 text, 1-3 headings, 4 bullet, 5 number, 8 slide), align byte, kids var, text length var, the UTF-8 text, runs var, then each run: length var, attributes byte (1 bold, 2 italic, 4 underline, 8 struck) |
| 2 | grid | flags byte (1: a header row), rows var, columns var, name length var, name, cells var, then each cell that holds anything: row var, column var, length var, what was typed |
| 3 | image | width var, height var, encoding byte (0: R,G,B a pixel, row by row), caption length var, caption, the pixels |
| 0x10 | view | the view byte (0 pages, 1 slides, 2 grid), the cursor's block var, its offset var |

Values are not saved. Formulas are worked out again as the file is read, so
a file holds only what was typed.

Copy and paste use the same format for a piece of a document. Undo keeps a
snapshot of the document in it before each change.

## Inside

compose.asm is only a platform layer. It handles the memory, the kit's
window and the presenter's window, their events, and the store. Everything else is in
src/user/compose/ and is plain code: events go in, pixels come out.

| file | what |
|---|---|
| doc.inc | blocks, their text and attributes, grids' cells, the arena |
| calc.inc | numbers, the formula parser and evaluator, recalculation |
| file.inc | the .axd format, plain text, CSV |
| layout.inc | pages, slides and frame cards laid out: a display list and a line table |
| edit.inc | the cursor, selection, typing, structure, cells, undo, the clipboard |
| draw.inc | drawing in points at a scale: web/draw.inc's DejaVu, kit.inc's Noto for the UI |
| ui.inc | the palettes (the window's from the desktop's look, the paper's), buttons through the kit |
| view.inc | the toolbar, each view, the thumbnails, the presenter (scaled bilinear) |
| app.inc | keys, clicks, the wheel, saving, opening, presenting |

The document's text is drawn with web/draw.inc in anti-aliased DejaVu: the
faces and sizes of gen/webfont.bin, which browse uses too, and twice those
sizes for screens at two pixels a point (tools/mkdocfont.py). Both are packed
into gen/docfont.pak, about 11 MB, which compose unpacks as it starts: a
program is 16 MiB at most, and they are 28 MB unpacked. At other scales, a
glyph is drawn from the size nearest.

The window's own text (the toolbar, the status line, the formula bar) is
the desktop's Noto Sans, through the kit.

The same code runs on Windows in tools/test/compose/:

- shim.asm links the .inc files and kit.inc into a DLL, with the desktop's
  look made as the kernel makes it (its fonts, theme.asm's colours);
- host.py drives the DLL;
- calc.py tests the formulas;
- app.py tests the program, taking screenshots in build/test/compose/.

run.py runs the host tests and then a QEMU boot that uses the keyboard and
the mouse.
