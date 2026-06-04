# 内联图片（Kitty Graphics）

*[English](Inline-Images) · 中文*

> 在终端里内联显示图片和 PDF 页面 —— 包括来自远程 shell 的。

## 功能说明

WispTerm 接受 Kitty Graphics 协议的图片输出，因此远程 shell 只要发出正确的转义序列，
就能内联显示图片和 PDF 页面。

## imgcat.py / pdfcat.py

仓库附带两个供服务端使用的辅助脚本
（[`tools/`](https://github.com/xuzhougeng/wispterm/tree/main/tools)）：

- `tools/imgcat.py` —— 把图片文件发送到终端。
- `tools/pdfcat.py` —— 把一页或多页 PDF 栅格化后发送。

```bash
python3 tools/imgcat.py screenshot.png
python3 tools/imgcat.py diagram.jpg --cols 100
python3 tools/pdfcat.py paper.pdf --page 1
python3 tools/pdfcat.py slides.pdf --page 2 --page 3 --cols 120
```

## 依赖与说明

- `imgcat.py` 直接发送 PNG；非 PNG 输入需要 **Pillow** 或 **ImageMagick**。
- `pdfcat.py` 需要 `pdftoppm`、`mutool` 或 **ImageMagick** 之一。
- 这些脚本应在 WispTerm 内的**远程机器**上运行，而非 Windows 宿主端。把它们复制到
  服务器（或放在共享路径），通过 SSH 在那里运行 —— 见
  [[SSH 与远程开发|SSH-Remote-Development-zh]]。

---
*另见：[[SSH 与远程开发|SSH-Remote-Development-zh]] · [[主题与外观|Themes-Appearance-zh]]*
