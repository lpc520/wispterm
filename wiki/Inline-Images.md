# Inline Images (Kitty Graphics)

*English · [中文](Inline-Images-zh)*

> Display images and PDF pages inline in the terminal — including from remote shells.

## What it does

WispTerm accepts Kitty Graphics protocol image output, so a remote shell can
display inline images and PDF pages if it emits the right escape sequences.

## imgcat.py / pdfcat.py

The repository ships two helper scripts for server-side use
([`tools/`](https://github.com/xuzhougeng/wispterm/tree/main/tools)):

- `tools/imgcat.py` — send an image file to the terminal.
- `tools/pdfcat.py` — rasterize one or more PDF pages and send them.

```bash
python3 tools/imgcat.py screenshot.png
python3 tools/imgcat.py diagram.jpg --cols 100
python3 tools/pdfcat.py paper.pdf --page 1
python3 tools/pdfcat.py slides.pdf --page 2 --page 3 --cols 120
```

## Requirements & notes

- `imgcat.py` sends PNG directly; non-PNG inputs require **Pillow** or
  **ImageMagick**.
- `pdfcat.py` requires one of `pdftoppm`, `mutool`, or **ImageMagick**.
- The scripts are meant to run on the **remote machine** inside WispTerm, not on
  the Windows host. Copy them to the server (or keep them on a shared path) and
  run them there over SSH — see [[SSH-Remote-Development]].

---
*See also: [[SSH-Remote-Development]] · [[Themes-Appearance]]*
