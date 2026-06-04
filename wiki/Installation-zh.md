# 安装

*[English](Installation) · 中文*

> 在 Windows 或 macOS 上下载运行 WispTerm，或从源码构建。

WispTerm 提供 **Windows** 与 **macOS** 版本。Linux 移植仍在进行中（见
[`TODO.md`](https://github.com/xuzhougeng/wispterm/blob/main/TODO.md)）。

## Windows

1. 从 [GitHub Releases](https://github.com/xuzhougeng/wispterm/releases) 下载最新
   Windows 版本。
2. 解压后运行 **`wispterm.exe`**。

WispTerm 不会自行提权 —— 普通方式启动得到的是标准权限令牌。需要管理员 shell 时，
右键 `wispterm.exe` 选择 **以管理员身份运行**（见 [[常见问题|FAQ-zh]]）。

**便携配置（仅 Windows）：** 在 `wispterm.exe` 旁放一个名为 `wispterm.conf` 的文件，
WispTerm 就会用它作为配置，整套设置可随 U 盘或共享目录携带。

## macOS

需要 **macOS 13+**。下载与你 CPU 对应的 `.app`（Apple Silicon 或 Intel），移动到
`/Applications`。

- 正常双击启动 **`WispTerm.app`**，**或**
- 直接运行二进制以传入 CLI 参数：
  ```bash
  WispTerm.app/Contents/MacOS/wispterm --version
  ```

> 传入命令行选项必须用二进制路径 —— 双击 `.app` 无法附带参数。

## 从源码构建

需要 **Zig 0.15.2**。

Windows（PowerShell）：

```powershell
zig build                         # 开发用 Debug 构建
zig build -Doptimize=ReleaseFast  # 发布用 ReleaseFast 构建
```

macOS：

```bash
zig build macos-app -Dtarget=aarch64-macos   # Apple Silicon（Intel 用 x86_64-macos）
open zig-out/bin/WispTerm.app
```

完整的构建、打包与发布细节见
[`docs/development.md`](https://github.com/xuzhougeng/wispterm/blob/main/docs/development.md)。

## 验证安装

```bash
wispterm --version            # 打印 WispTerm 版本
wispterm --show-config-path   # 打印解析出的配置文件路径
```

下一步：**[[快速上手|Getting-Started-zh]]**。

---
*另见：[[快速上手|Getting-Started-zh]] · [[配置|Configuration-zh]]*
