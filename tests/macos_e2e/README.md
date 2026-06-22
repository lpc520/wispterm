# macOS UI E2E 测试

本地运行的端到端 GUI 测试:启动隔离的真实 `WispTerm.app`,用真实 OS 输入驱动,
断言终端正文与窗口/菜单状态。

## 运行

```bash
make test-macos-e2e
```

会先按本机架构构建 `macos-app` + `wisptermctl`,确保 `pytest` 在位(缺则
`pip install --user pytest`),再用 `/usr/bin/python3 -m pytest tests/macos_e2e`。

只跑无需 GUI 的纯逻辑单测:

```bash
/usr/bin/python3 -m pytest tests/macos_e2e -m "not e2e"
```

## 前置条件

- macOS + Xcode 或 Command Line Tools(提供 `/usr/bin/python3`)。
- **PyObjC**(非系统自带,需一次 pip):
  `/usr/bin/python3 -m pip install --user pyobjc-framework-Quartz pyobjc-framework-Cocoa`。
  未安装时 e2e 用例自动 skip 并给出该命令。
- **pytest**:`make` 入口会在缺失时自动 `pip install --user pytest`。
- 运行 pytest 的终端需在 **系统设置 → 隐私与安全性 → 辅助功能** 中授权
  (CGEvent 注入 + System Events 控制);未授权时 e2e 用例自动 skip 并提示。
- 解释器固定用 `/usr/bin/python3`(其 user-site 挂着 PyObjC);其他 python 可能没有 PyObjC。

## 隔离

每次 session 用临时 `HOME`,在其中写 `config`(开启 `agent-control-enabled`、
关闭 `auto-update-check`)。所有 `wisptermctl` 调用带同一 `HOME`,只连测试实例,
**不影响你正在用的开发实例**。

## 结构

- `driver/base.py` — 跨平台抽象接口(用例只依赖它)
- `driver/macos.py` — MacDriver:CGEvent(键鼠)+ osascript(菜单/AX)+ wisptermctl(正文)
- 纯逻辑模块(`panes`/`keycodes`/`wait`/`osascript` 构造/`ctl` 装配)有单元测试,无需 GUI
- `test_smoke.py` / `test_keybinds.py` / `test_menu.py` — 标 `@pytest.mark.e2e`

## 已知问题(调试中)

纯逻辑单测全部通过。但 **3 个 e2e 冒烟用例在开发机上当前会失败**:合成的键盘输入
没有送达到运行中的 `WispTerm` 窗口。已排查并确认的事实(用于继续定位,勿重复走):

- ✅ 控制通道 `wisptermctl send-text` 能正常写入 surface 并被 `get-text` 读到 —— 说明
  surface / shell / get-text 链路完好,问题只在 **OS 级输入注入**。
- ✅ CGEvent **鼠标移动**注入有效(光标会移动)—— 说明本进程能向会话注入事件。
- ✅ 测试实例确实是真实前台 app(`NSWorkspace.frontmostApplication` = 测试 PID,
  `activationPolicy = Regular`),且其窗口是 key/main(`AXFocusedWindow` 存在、
  `AXMain`/`AXFocused` = true)。
- ✅ `IsSecureEventInputEnabled()` 全程为 0 —— **不是** Secure Keyboard Entry。
- ✅ `osascript ... keystroke` 返回 exit 0(无 TCC 拒绝报错),但文本仍不落地。
- ❌ CGEvent 键盘(HID tap / session tap)、System Events `keystroke`、`key code`、
  以及"点击窗口中心后再输入"均无法让文本进入终端;`Cmd+T` 也不触发新建标签
  (即键盘连 app 的菜单/keybind 都没收到)。

即:app 前台、窗口 key、鼠标可注入、控制通道可用,但**键盘事件就是不被该 app 接收**。
下一步可探查方向:① 该 app 自定义窗口/输入处理是否对合成 keyDown 有特殊过滤;
② 运行环境(经 Claude 桌面端派生的进程链)对"键盘事件投递到其它 app"的 TCC 归属
是否与 `AXIsProcessTrusted()` 报告的不一致(鼠标可注入但键盘投递被静默丢弃);
③ 改用真正的物理终端(iTerm/Terminal)直接 `make test-macos-e2e` 复测以隔离环境因素。

## 扩展 / Windows

新增后端 `driver/windows.py`(`SendInput` via ctypes + UI Automation),
正文层(`get_text`/`wait_for`/`primary_pane`)直接复用;`conftest` 按平台选后端。
