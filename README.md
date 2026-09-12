# DSH Web 启动器

给 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的浏览器 GUI 做一个
**Dock 图标**：点一下就起服务、开出满屏的应用窗口，再配一个**菜单栏常驻图标**管状态与退出。
等价于在终端执行 `dsh web`，但省掉了每次敲命令、认端口、关窗口又不知道服务还活着这些事。

窗口用 **Chrome 应用模式**（`--app`）承载：没有标签栏和地址栏，并且**复用你日常的 Chrome
配置与实例**——启动快、有浏览缓存、不额外起 Chrome 进程、也不会多出一个 Dock 图标。

## 前置要求

| 依赖 | 说明 |
|---|---|
| macOS | 用到 `AppleScript`、`NSCocoa`、`lsof`、`sips`／`iconutil` |
| 已安装 `dsh` | 脚本里用绝对路径调它（见下方"自定义"里的 `DSH_BIN`） |
| Google Chrome | 装在 `/Applications/Google Chrome.app` |
| Xcode 命令行工具 | 只有**重新编译** Swift 工具时才需要（`xcode-select --install`） |

## 快速开始

```sh
git clone https://github.com/kaidiren/dsh-launcher.git ~/dsh/dsh-launcher
cd ~/dsh/dsh-launcher
./build.sh                                  # 编译工具 + 生成图标 + 组装 app
cp -R "DSH Web.app" /Applications/          # 需要写 /Applications 的权限
```

然后 Finder → 应用程序 → 把 **DSH Web** 拖到 Dock 左半边（应用区）。之后单击图标即可。

> 首次点击时系统可能问「『DSH Web』想要控制『Google Chrome』」——**点允许**，
> 否则窗口检测会失败（症状是每点一次都多开一个窗口）。

## 目录结构

**源码（提交进仓库）**

| 文件 | 作用 |
|---|---|
| `launch-dsh-web.sh` | 主逻辑：进程检测、窗口检测/开窗、满屏、菜单栏图标拉起、整体停止 |
| `dsh-tray.swift` | 菜单栏常驻图标（黑鲸鱼）：状态显示、打开窗口、重启、退出 |
| `screen-bounds.swift` | 小工具：输出屏幕可用区域，供窗口撑满用 |
| `make-icon.swift` | 早期用 CoreGraphics 画图标的脚本（现在图标来自 `icons/`） |
| `build.sh` | 一键构建 |
| `Info.plist` | `DSH Web.app` 的 bundle 描述 |
| `icons/` | 图标资源，取自 [anywhere-labs/dsh-desktop](https://github.com/anywhere-labs/dsh-desktop) |

**生成物（不提交）**：`DSH Web.app/`、`AppIcon.icns`、`AppIcon.iconset/`、
`dsh-tray`、`screen-bounds`、`icon-1024.png`，以及运行期产物
`dsh-web.log`／`chrome.log`／`tray.log`／`dsh-web.pid`／`dsh-web.url`、
标志文件 `.dsh-stop-request-<端口>`／`.dsh-restart-request-<端口>`、`.module-cache/`。

## 行为

点一次图标做两件事，各自都有检测，**进程和窗口都不会重复**：

**1. 进程检测** —— `lsof` 查端口（默认 3080）是否已有 LISTEN：

- 有 → 复用现有进程，**绝不重启**；顺手补写缺失的 `dsh-web.pid`
- 没有 → 后台 `nohup` 拉起 `dsh web --port 3080 --no-open`，等端口就绪后从日志里
  取回 dsh 打印的**带 token 认证 URL** 存进 `dsh-web.url`（首次访问靠它换 cookie）

**2. 窗口检测** —— AppleScript 枚举 Chrome 窗口，找 URL 含 `127.0.0.1:3080` 的那个：

- 有 → 提到最前，并**顺手撑满屏幕**（窗口可能是改成满屏之前开的）
- 没有 → 开一个应用窗口，同样撑满

另外整段流程用 `mkdir` 原子锁**串行化**：连点图标时不会并发启动多个服务、也不会并发开窗。

**关掉窗口（点 ×）不影响服务**：`dsh web` 是 `nohup` 起的独立进程，窗口只是它的一个客户端。
下次点击会把窗口开回来。

服务启动等待上限约 60 秒，token 再等最多 15 秒。

**认证 URL 随时可找回**：`dsh-web.url` 缓存丢失时（被清理过、或某次启动没抓到 token），
启动器会去 `dsh-web.log` 里翻最后一次出现的认证 URL 补写回缓存。日志是追加写的，
所以"最后一次出现的 token"就是当前服务的 token——不必为了拿回地址而重启服务。
日志里出现过 token 就是本机凭据，别外传，也别把日志提交进仓库（`.gitignore` 已排除 `*.log`）。

## 菜单栏图标

`dsh-tray` 是菜单栏上的一只**黑鲸鱼**——它在，就代表 DSH 在跑：

- **左键** → 打开/聚焦窗口
- **右键** → 三项菜单：
  - `打开`（⌘O）→ 同左键
  - `重启`（⌘R）→ 关窗口 + 停服务 + 重新拉起 + 重开窗口（改了配置、或 cookie/认证状态乱了时用）
  - `退出`（⌘Q）→ 关窗口 + 停后台进程 + 撤掉菜单栏图标

`打开` 和 `重启` 之后托盘继续常驻；只有 `退出` 会让它自己消失。
启动器开好窗口后会自动拉起托盘（已在跑就不重复启动，并把当前端口传给它）。不想要就把脚本里的
`DSH_TRAY` 默认值改成 `0`。它每个动作都会写 `tray.log`，点菜单没反应时先看那里。

托盘也只会有一个：它启动时把 pid 写进 `dsh-tray.pid`，启动器先读这个文件、再拿 `pgrep` 兜底，
两边都对不上才新起一个——否则菜单栏上会出现两只鲸鱼。

## 自定义

从 Dock 点击时无法传环境变量，改脚本开头的默认值即可：

```sh
PORT="${DSH_WEB_PORT:-3080}"                # 服务端口
WIN_MODE="${DSH_WINDOW_MODE:-maximized}"    # 窗口尺寸：maximized 占满屏幕 | custom
WIN_W="${DSH_WINDOW_WIDTH:-1180}"           # 仅 custom 模式使用
WIN_H="${DSH_WINDOW_HEIGHT:-800}"
REUSE_WINDOW="${DSH_REUSE_WINDOW:-1}"       # 0 = 不做窗口检测，每次直接开
TRAY_ENABLED="${DSH_TRAY:-1}"               # 0 = 不启动菜单栏图标
WORKDIR="${DSH_WORKDIR:-/Users/rkd/dsh}"    # GUI 会话的起始目录
DSH_BIN="${DSH_BIN:-...}"                   # dsh 可执行文件绝对路径
FLAG_MAX_AGE="${DSH_FLAG_MAX_AGE:-90}"      # 停止/重启标志的有效期（秒），过期不执行
```

`launch-dsh-web.sh` 是唯一的真源：改它立即生效，不用重装 app（`.app` 只是个薄壳）。
只有改了 `Info.plist`、图标或 Swift 源码时才需要重跑 `./build.sh`。

自检：`DSH_LAUNCHER_DRY_RUN=1 ./launch-dsh-web.sh` 只做决策不做动作。

## 实现上的几个坑

都是实际踩过的，改动时注意别踩回去：

1. **不能用 `open -na "Google Chrome" --args ...`。** 日常 Chrome 已在运行时，
   LaunchServices 会把请求转交给已有实例并**丢掉 `--args`**，参数根本不生效
   （实测：既没新实例，窗口也没开）。脚本改为直接执行
   `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"`。

2. **不要用独立 Chrome 配置（`--user-data-dir`）。** 试过，代价很大：新 profile 首次
   启动要做一堆初始化（组件下载、GCM 注册、TFLite 初始化），而且**没有浏览缓存**，
   DSH 前端每次都要重新拉全部资源——结果是「打开巨卡、加载不出来」；还会额外占一份
   内存，并在 Dock 上多出一个 Chrome 图标。

3. **窗口检测不能用 CDP。** 独立配置下可以用 `--remote-debugging-port` 走 CDP，
   但既然要复用日常 Chrome 就用不了——Chrome 禁止在默认配置上开远程调试端口。

4. **`--start-maximized` 在 Chrome 已运行时会被丢弃。** 实测新窗口仍是上次记忆的尺寸，
   得手双击标题栏才能最大化。所以改成自己取屏幕可用区域（`screen-bounds`）再用
   AppleScript `set bounds` 撑满。

5. **AppleScript 不要用 heredoc 管道喂给 `osascript`。** 在「后台执行 + 管道」的组合下
   stdin 拿不到脚本内容，osascript 会**「成功」返回空字符串**（rc=0、无输出、不报错），
   症状就是每次都判定「没有窗口」而重复开窗。改为先把 AppleScript 写进临时文件再执行。

6. **AppleScript 里不要写 `set active tab index of w to (index of t)`。** Chrome 会报
   `-10006 不能将「…」设置为「…」`，整个脚本报错、输出为空，同样表现为重复开窗。
   应用窗口只有一个标签页，本来也不需要切标签。

7. **AppleScript 的权限按「发起进程」判定，别从托盘直接发。** 同一个脚本，经 app/launchd
   启动时能正常控制 Chrome；由菜单栏托盘（裸二进制）派生出来跑，就会被 TCC 拒掉
   （`-1743 未获得授权将 Apple 事件发送给 Google Chrome`），症状正是「从 Dock 启动后
   再点菜单栏图标就重复开窗口」。所以托盘里的动作都改成
   `open -a "/Applications/DSH Web.app"` 交给 app 去做；「退出 DSH」另写一个
   `.dsh-stop-request-<端口>` 标志，由 app 看到后执行关窗口 + 停服务 + 撤图标。
   「重启」同理，写 `.dsh-restart-request-<端口>`。

8. **标志文件要带端口、还要有保质期。** 一开始标志叫 `.dsh-stop-request`，不带端口——
   于是任何一次「在别的端口上做实验」留下的标志，都会被**正在用的那个实例**认领成
   自己的请求，把用户的服务重启掉（实际发生过：浏览器随即提示需要重新认证）。
   现在文件名带端口，且只认自己端口（外加旧版无后缀名，兼容老托盘）；同时
   `take_flag` 只看**90 秒内**写入的标志，陈旧的一律清掉不执行（`DSH_FLAG_MAX_AGE` 可调）。

9. **在 Rosetta 下跑 `build.sh` 会编译失败。** 如果 shell 自己跑在 Rosetta 下
   （`uname -m` 报 `x86_64`，而机器是 Apple Silicon），`swiftc` 会按 x86_64 编译，
   而 SDK 里没有对应的 Swift 模块接口，报 `failed to build module 'Swift'`。
   `build.sh` 现在会检测 `sysctl -n hw.optional.arm64` 并自动改用 `arch -arm64 swiftc`。

> 第 5、6、7 条这类失败**不会弹授权框、日志里也不显眼**，所以别用「有没有弹窗」来判断
> 权限问题。调试时保留 `run_limited` 里的 `2>&1`，错误信息才会进日志。

## 排错

**窗口里只显示空白引导页、看不到会话**
先别怀疑数据丢了——会话和工作区数据在 `~/.dsh/` 下，通常是好的。这种情况是浏览器里
**那个 origin 的本地状态**（`dsh.workspace.view.v5`、`dsh.sessions.current` 等键）坏了。
判定：用 Safari 或 Chrome 无痕窗口打开同一个 token URL，那边正常就说明是它。
修复：在空白窗口按 `Cmd+Option+J`，执行

```js
Object.keys(localStorage).filter(k => k.startsWith('dsh')).forEach(k => localStorage.removeItem(k)); location.reload()
```

**每点一次就多一个窗口**
窗口检测失败了。依次检查：Chrome 是否已授权自动化（系统设置 → 隐私与安全性 → 自动化）、
`dsh-web.log` 里 `窗口检测：结果=` 那行返回的是 `focused` 还是空/报错。

**点了菜单栏图标没反应**
看 `tray.log`。里面会记「动作：打开窗口 / 重启 DSH / 退出 DSH」；如果只有「图标被点击」
没有后续动作，说明菜单项的 action 没派发（早期版本用「挂菜单 → performClick → 立刻摘掉」
会这样，现在改用 `popUpMenu` 同步弹菜单）。

**浏览器里提示需要认证 / `dsh web authentication required`**
服务重启后进程 token 变了，浏览器里旧 cookie 就失效了（表现为「请重新打开 dsh web 打印的地址」）。
取回当前地址：

```sh
cat ~/dsh/dsh-launcher/dsh-web.url        # 缓存；丢了的话看下一行
grep -a -o 'http://127\.0\.0\.1:3080/?token=[A-Za-z0-9_-]*' ~/dsh/dsh-launcher/dsh-web.log | tail -1
```

用该地址打开即可恢复。不想动命令行就右键菜单栏图标 → `重启`，会重新开一个带新 token 的窗口。
同理，如果只想让某个页面恢复，把它的地址换上新 token 即可；**token 是本机凭据，不要外传**。

## 其他

- `dsh-web.log` 与 `dsh-web.url` 里会记录带进程 token 的启动 URL
  （`dsh web: http://...?token=...`），那是本机凭据，**不要外传**；token 随进程重启失效。
- 停止服务：`kill "$(cat ~/dsh/dsh-launcher/dsh-web.pid)"`，或用菜单栏的「退出 DSH」。
- 为什么脚本里全是绝对路径：Finder/Dock 启动的进程 PATH 极简，不含 nvm 的 `node`/`dsh`，
  脚本已把 nvm 的 bin 目录补进 PATH。
- **图标来源**：`icons/` 下的应用图标与托盘图标取自
  [anywhere-labs/dsh-desktop](https://github.com/anywhere-labs/dsh-desktop)，
  使用时请遵守该项目的许可。`make-icon.swift` 是早期自绘图标的脚本，保留备查。
