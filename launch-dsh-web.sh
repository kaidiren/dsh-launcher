#!/bin/bash
# DSH Web 启动器 —— Dock / Finder 双击入口，等价于在终端执行 `dsh web`。
#
# 行为：
#   1. 进程检测：目标端口已有 dsh web 在监听 → 不重复启动。
#   2. 窗口检测：查 Chrome 是否已有指向本 GUI 的窗口 → 有就聚焦，没有才开。
#   3. 关闭窗口（点 ×）不会动后台的 dsh web 进程：进程是 nohup 起的独立进程，
#      窗口只是它的一个客户端；下次点击复用同一个进程，只把窗口开回来。
#   4. 窗口用 Chrome 应用模式（--app）：独立窗口、无标签栏和地址栏、固定小尺寸。
#      复用你日常的 Chrome 配置与实例——不额外起 Chrome，启动快、有浏览缓存，
#      Dock 上也不会多出一个 Chrome 图标。
#   5. 菜单栏常驻图标（dsh-tray）：显示后台服务状态，左键打开窗口、右键出菜单。
#   6. 全过程写入 dsh-web.log，便于排查。
#
# 环境变量（可选）：
#   DSH_WEB_PORT            服务端口，默认 3080
#   DSH_BIN                 dsh 可执行文件绝对路径
#   DSH_WORKDIR             dsh web 的工作目录（决定 GUI 会话的起始目录）
#   DSH_WINDOW_MODE         窗口尺寸：maximized（默认，占满屏幕）| custom
#   DSH_WINDOW_WIDTH/HEIGHT 仅 custom 模式使用的窗口尺寸，默认 1180x800
#   DSH_REUSE_WINDOW        1（默认）复用已有窗口；0 则每次都开新窗口
#   DSH_TRAY                1（默认）启动菜单栏图标；0 则不启动
#   DSH_LAUNCHER_DRY_RUN    置 1 时只做决策不做动作（用于自检）
#
# 额外参数：本脚本收到的参数会原样转给 `dsh web`。Dock 点击时没有参数。

set -u

PORT="${DSH_WEB_PORT:-3080}"
DSH_BIN="${DSH_BIN:-/Users/rkd/.nvm/versions/node/v24.6.0/bin/dsh}"
WORKDIR="${DSH_WORKDIR:-/Users/rkd/dsh}"
LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${LAUNCHER_DIR}/dsh-web.log"
PID_FILE="${LAUNCHER_DIR}/dsh-web.pid"
URL_FILE="${LAUNCHER_DIR}/dsh-web.url"
CHROME_LOG="${LAUNCHER_DIR}/chrome.log"
TRAY_LOG="${LAUNCHER_DIR}/tray.log"
LOCK_DIR="${LAUNCHER_DIR}/.dsh-start.lock"
STOP_FLAG="${LAUNCHER_DIR}/.dsh-stop-request"
URL="http://127.0.0.1:${PORT}/"
CURL=/usr/bin/curl
LSOF=/usr/sbin/lsof
DRY_RUN="${DSH_LAUNCHER_DRY_RUN:-0}"

CHROME_APP="/Applications/Google Chrome.app"
CHROME_BIN="${CHROME_APP}/Contents/MacOS/Google Chrome"
WIN_MODE="${DSH_WINDOW_MODE:-maximized}"   # maximized（默认，占满屏幕）| custom
WIN_W="${DSH_WINDOW_WIDTH:-1180}"          # 仅 custom 模式使用
WIN_H="${DSH_WINDOW_HEIGHT:-800}"
REUSE_WINDOW="${DSH_REUSE_WINDOW:-1}"
TRAY_ENABLED="${DSH_TRAY:-1}"
NEEDLE="127.0.0.1:${PORT}"
TOKEN_RE="http://127\.0\.0\.1:${PORT}/?token=[A-Za-z0-9_-]*"

# Finder/Dock 启动的进程只有极简 PATH，这里补齐 nvm 的 node/dsh 与常用路径。
export PATH="/Users/rkd/.nvm/versions/node/v24.6.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="${HOME:-/Users/rkd}"

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"${LOG}" 2>/dev/null; }

# ---------- 进程检测 ----------
# 端口上有 LISTEN 就是服务在跑（比 HTTP 探测更直接，也不受认证状态影响）
service_running() { "${LSOF}" -nP -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; }

# 至多等 ${1} 秒执行剩余命令；超时返回 124，否则返回命令自身退出码
run_limited() {
  local secs="$1"; shift
  local out_file p rc waited
  out_file="$(mktemp "${LAUNCHER_DIR}/.dsh-focus.XXXXXX" 2>/dev/null)" || return 1
  "$@" >"${out_file}" 2>&1 &   # stderr 一起收：TCC/权限类错误都在这里
  p=$!
  waited=0
  while [ "${waited}" -lt "$((secs * 10))" ]; do
    kill -0 "${p}" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "${p}" 2>/dev/null; then
    kill "${p}" 2>/dev/null
    rm -f "${out_file}"
    return 124
  fi
  wait "${p}" 2>/dev/null
  rc=$?
  cat "${out_file}" 2>/dev/null
  rm -f "${out_file}"
  return "${rc}"
}

# 已有窗口则聚焦它并返回 0；否则返回 1。
# 走 AppleScript 枚举 Chrome 窗口，需要 macOS「自动化」权限：首次点击会弹一次
# 授权框，允许后长期有效；被拒则静默降级成「每次都开新窗口」，功能不受影响。
focus_existing_window() {
  [ "${REUSE_WINDOW}" = "1" ] || { log "窗口检测：已禁用（DSH_REUSE_WINDOW=0）"; return 1; }
  [ -d "${CHROME_APP}" ] || { log "窗口检测：找不到 Chrome"; return 1; }
  /usr/bin/pgrep -x "Google Chrome" >/dev/null 2>&1 || { log "窗口检测：Chrome 没在运行"; return 1; }
  local out rc
  # 超时给到 10 秒：第一次点击时系统会弹「想要控制 Google Chrome」授权框，
  # 必须留足时间等你点「允许」，否则会被当成「没有窗口」而重复开窗。
  # AppleScript 走临时文件，不用 heredoc 管道：管道 + 后台执行时 stdin 可能拿不到
  # 脚本内容，osascript 会「成功」返回空字符串——实测踩过，表现就是每次都重复开窗。
  local script_file="${LAUNCHER_DIR}/.dsh-focus.applescript"
  cat >"${script_file}" <<APPLESCRIPT
if application "Google Chrome" is running then
	tell application "Google Chrome"
		repeat with w in windows
			repeat with t in tabs of w
				if (URL of t) contains "${NEEDLE}" then
					activate
					set index of w to 1
					return "focused"
				end if
			end repeat
		end repeat
	end tell
end if
return "none"
APPLESCRIPT
  out="$(run_limited 10 /usr/bin/osascript "${script_file}")"
  rm -f "${script_file}"
  rc=$?
  if [ "${rc}" = "124" ]; then
    log "窗口检测：osascript 超时 —— 多半是「自动化」权限在等授权或被拒；去 系统设置 → 隐私与安全性 → 自动化 里允许控制 Google Chrome"
    return 1
  fi
  if [ "${rc}" != "0" ]; then
    log "窗口检测：osascript 失败 rc=${rc}（被拒时通常是 -10004 权限违例）"
    return 1
  fi
  log "窗口检测：结果=[${out}]"
  [ "${out}" = "focused" ]
}

# 用 Chrome 应用窗口打开 GUI。
# 关键：直接执行 Chrome 二进制，而不是 `open -na ... --args`。
#   · `open -na` 在 Chrome 已运行时会把请求转给已有实例并丢掉 --args，参数根本不生效；
#   · 直接执行二进制、不带 --user-data-dir 时 Chrome 用你日常的配置：已经在跑就复用
#     它（只多开一个应用窗口，不产生新实例），没在跑就启动它。启动快、有缓存。
open_app_window() {
  local url="$1"
  if [ "${WIN_MODE}" = "maximized" ]; then
    # 默认占满屏幕；实测 --start-maximized 在应用窗口上有效（bounds 等于整屏）
    nohup "${CHROME_BIN}" --start-maximized --app="${url}" >>"${CHROME_LOG}" 2>&1 &
  else
    nohup "${CHROME_BIN}" --window-size="${WIN_W},${WIN_H}" --app="${url}" >>"${CHROME_LOG}" 2>&1 &
  fi
}

# 把 GUI 窗口撑满屏幕可用区域。
# 不能用 --start-maximized：Chrome 已在运行时该参数会被丢弃（实测新窗口仍是
# 上次记忆的尺寸，得手双击标题栏才能最大化）。所以自己取屏幕几何再设 bounds。
maximize_gui_window() {
  local b
  b="$("${LAUNCHER_DIR}/screen-bounds" 2>/dev/null | head -1)"
  [ -n "${b}" ] || { log "  拿不到屏幕尺寸，跳过最大化"; return 0; }
  local sf="${LAUNCHER_DIR}/.dsh-max.applescript" r i=0
  cat >"${sf}" <<APPLESCRIPT
tell application "Google Chrome"
	repeat with w in windows
		repeat with t in tabs of w
			if (URL of t) contains "${NEEDLE}" then
				set bounds of w to {${b}}
				return "maximized"
			end if
		end repeat
	end repeat
end tell
return "none"
APPLESCRIPT
  while [ "${i}" -lt 24 ]; do          # 新窗口要一点时间才出现，最多等 12 秒
    r="$(run_limited 10 /usr/bin/osascript "${sf}")"
    if [ "${r}" = "maximized" ]; then
      rm -f "${sf}"
      log "  窗口已撑满屏幕（${b}）"
      return 0
    fi
    i=$((i + 1))
    sleep 0.5
  done
  rm -f "${sf}"
  log "  超时未能撑满窗口（可能窗口还没建出来）"
  return 0
}

ensure_window() {
  local fallback="${1:-${URL}}"
  if [ "${DRY_RUN}" = "1" ]; then echo "WOULD_OPEN ${fallback}"; return 0; fi

  if [ ! -d "${CHROME_APP}" ]; then
    log "未找到 Chrome，退回默认浏览器：${fallback}"
    /usr/bin/open "${fallback}"
    return 0
  fi

  if focus_existing_window; then
    log "窗口已存在，聚焦它，未重复开窗"
    # 顺带确保它是满屏的：窗口可能是改成满屏之前开的、或用户手动缩过，
    # 只聚焦的话它会一直保持那个尺寸。
    if [ "${WIN_MODE}" = "maximized" ]; then
      maximize_gui_window
    fi
    return 0
  fi

  log "打开 Chrome 应用窗口（${WIN_MODE}）：${fallback}"
  open_app_window "${fallback}"
  if [ "${WIN_MODE}" = "maximized" ]; then
    maximize_gui_window
  fi
}

# ---------- 整体停止 ----------
# 关掉 GUI 窗口 → 停掉后台服务 → 撤掉菜单栏图标。
# 由菜单栏「退出 DSH」触发：托盘先写下 STOP_FLAG，再用 open -a 拉起本 app。
# 必须绕这一圈：AppleScript 的权限是按「发起进程」判定的，从托盘（裸二进制）
# 直接发会被 TCC 拒掉（-1743 未授权发送 Apple 事件），而经 app 启动就和点 Dock 一致。
do_stop_all() {
  log "整体停止：关窗口 → 停服务 → 退菜单栏图标"

  if [ -d "${CHROME_APP}" ] && /usr/bin/pgrep -x "Google Chrome" >/dev/null 2>&1; then
    local sf="${LAUNCHER_DIR}/.dsh-close.applescript" res
    cat >"${sf}" <<APPLESCRIPT
if application "Google Chrome" is running then
	tell application "Google Chrome"
		repeat with w in windows
			repeat with t in tabs of w
				if (URL of t) contains "${NEEDLE}" then
					close w
					exit repeat
				end if
			end repeat
		end repeat
	end tell
end if
return "closed"
APPLESCRIPT
    res="$(run_limited 10 /usr/bin/osascript "${sf}")"
    rm -f "${sf}"
    log "  关闭窗口结果：${res:-（空）}"
  fi

  if [ -f "${PID_FILE}" ]; then
    local pid
    pid="$(cat "${PID_FILE}" 2>/dev/null)"
    if [ -n "${pid}" ]; then
      kill "${pid}" 2>/dev/null && log "  已停止服务 pid=${pid}"
    fi
    rm -f "${PID_FILE}" "${URL_FILE}"
  else
    log "  没有 pid 文件，跳过停服务"
  fi

  /usr/bin/pkill -f "${LAUNCHER_DIR}/dsh-tray" 2>/dev/null && log "  已撤掉菜单栏图标"
  return 0
}

# ---------- 流程互斥锁 ----------
# 连点图标时会有多个启动器同时跑：它们会各自看到「端口空闲」而重复启动服务、
# 各自看到「没有窗口」而重复开窗。用原子 mkdir 做锁，把整段流程排队。
acquire_start_lock() {
  local i=0 holder
  while [ "${i}" -lt 240 ]; do          # 最多等约 120 秒；服务冷启动约 10 秒，其余点击排队
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      printf '%s\n' "$$" >"${LOCK_DIR}/pid" 2>/dev/null
      return 0
    fi
    holder="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")"
    if [ -n "${holder}" ] && ! kill -0 "${holder}" 2>/dev/null; then
      log "清理陈旧的锁（持有者 ${holder} 已退出）"
      rm -rf "${LOCK_DIR}" 2>/dev/null
      continue
    fi
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

release_start_lock() { rm -rf "${LOCK_DIR}" 2>/dev/null; }

# ---------- 菜单栏常驻图标 ----------
# 显示后台服务状态：运行中为蓝色鲸鱼，未运行是跟随菜单栏明暗的模板图标。
# 左键点击打开/聚焦窗口，右键出菜单（打开窗口 / 停止服务 / 退出图标）。
ensure_tray() {
  [ "${TRAY_ENABLED}" = "1" ] || return 0
  [ "${DRY_RUN}" = "1" ] && { echo "WOULD_START_TRAY"; return 0; }
  [ -x "${LAUNCHER_DIR}/dsh-tray" ] || return 0
  if /usr/bin/pgrep -f "${LAUNCHER_DIR}/dsh-tray" >/dev/null 2>&1; then
    return 0
  fi
  nohup "${LAUNCHER_DIR}/dsh-tray" >>"${TRAY_LOG}" 2>&1 &
  log "菜单栏图标已启动（pid=$!）"
}

log "---- 启动器被触发（port=${PORT}, dry_run=${DRY_RUN}）----"

# 整段流程串行化：连点图标时会有多个启动器同时在跑，它们会各自看到「端口空闲」
# 而重复启动服务、各自看到「没有窗口」而重复开窗。用原子锁把整段流程排队，
# 只有当前这个在跑，后面排队的等它做完再判断——进程和窗口就都不会重复。
if [ "${DRY_RUN}" != "1" ]; then
  if ! acquire_start_lock; then
    log "等锁超时（另一个启动器迟迟不结束），本次放弃"
    exit 1
  fi
  trap 'release_start_lock' EXIT INT TERM
fi

# ---------- 停止请求（来自菜单栏「退出 DSH」）----------
if [ -f "${STOP_FLAG}" ]; then
  rm -f "${STOP_FLAG}"
  do_stop_all
  exit 0
fi

# ---------- 情况一：服务已在运行 ----------
if service_running; then
  log "服务已在运行（端口 ${PORT} 有监听），不重复启动进程"
  # PID 文件缺失或已过期时，从端口反查补写。
  # 菜单栏「退出 DSH」靠这个文件停服务；用户重启过服务、或清理过状态文件之后，
  # 若一直不补，退出就只会关窗口、停不掉后台进程。
  if [ ! -f "${PID_FILE}" ] || ! kill -0 "$(cat "${PID_FILE}" 2>/dev/null)" 2>/dev/null; then
    RUNNING_PID="$(/usr/sbin/lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t 2>/dev/null | head -1)"
    if [ -n "${RUNNING_PID}" ]; then
      printf '%s\n' "${RUNNING_PID}" >"${PID_FILE}" 2>/dev/null
      log "已从端口反查补写 pid=${RUNNING_PID}"
    fi
  fi
  SHOWN_URL="${URL}"
  if [ -f "${URL_FILE}" ]; then
    CACHED="$(head -1 "${URL_FILE}" 2>/dev/null)"
    # 只认端口匹配的缓存：改过端口后旧文件指向的是旧服务的地址，直接用会开错窗口
    case "${CACHED}" in
      *"127.0.0.1:${PORT}/"*) SHOWN_URL="${CACHED}" ;;
      *) log "忽略过期的 URL 缓存（端口不是 ${PORT}）：${CACHED}" ;;
    esac
  fi
  ensure_window "${SHOWN_URL}"
  ensure_tray
  exit 0
fi

# ---------- 情况二：服务没跑，由本脚本拉起 ----------
if [ ! -x "${DSH_BIN}" ]; then
  log "错误：找不到可执行的 dsh：${DSH_BIN}"
  /usr/bin/osascript -e 'display alert "DSH Web 启动失败" message "找不到 dsh 可执行文件，请检查 dsh-launcher/launch-dsh-web.sh 里的 DSH_BIN。" as critical' >/dev/null 2>&1
  exit 1
fi

BEFORE_LINES="$(wc -l <"${LOG}" 2>/dev/null | tr -d ' ')"
[ -n "${BEFORE_LINES}" ] || BEFORE_LINES=0

log "启动 dsh web（bin=${DSH_BIN}, cwd=${WORKDIR}）"
if [ "${DRY_RUN}" = "1" ]; then echo "WOULD_START ${DSH_BIN} web --port ${PORT} --no-open"; exit 0; fi

cd "${WORKDIR}" 2>/dev/null || cd "${HOME}" || cd /
# nohup：进程独立于窗口和启动器存活，关窗口、关启动器都不会影响它
# --no-open：浏览器交给本脚本用「应用窗口」打开，不让 dsh 用默认浏览器开标签
nohup "${DSH_BIN}" web --port "${PORT}" --no-open "$@" >>"${LOG}" 2>&1 &
CHILD=$!
echo "${CHILD}" >"${PID_FILE}" 2>/dev/null
log "dsh web 已拉起，pid=${CHILD}（日志 ${LOG}）"

# 阶段一：等端口就绪（最多约 60 秒）
READY=0
for _ in $(seq 1 300); do          # 0.2 秒探一次，上限仍是 60 秒
  sleep 0.2
  if service_running; then READY=1; break; fi
  if ! kill -0 "${CHILD}" 2>/dev/null; then
    log "dsh web 提前退出，请查看日志末尾"
    /usr/bin/osascript -e "display alert \"DSH Web 启动失败\" message \"dsh web 进程提前退出，详见 ${LOG}\" as critical" >/dev/null 2>&1
    rm -f "${PID_FILE}"
    exit 1
  fi
done

if [ "${READY}" != "1" ]; then
  log "超时：端口 ${PORT} 仍未就绪"
  exit 1
fi
log "服务就绪：${URL}"

# 阶段二：只在本次新增的日志里找带 token 的认证 URL，最多再等 15 秒
TOKEN_URL=""
for _ in $(seq 1 75); do           # 0.2 秒一次，最多再等 15 秒
  TOKEN_URL="$(/usr/bin/tail -n +$((BEFORE_LINES + 1)) "${LOG}" 2>/dev/null | /usr/bin/grep -a -o "${TOKEN_RE}" | /usr/bin/tail -1)"
  [ -n "${TOKEN_URL}" ] && break
  sleep 0.2
done

if [ -n "${TOKEN_URL}" ]; then
  printf '%s\n' "${TOKEN_URL}" >"${URL_FILE}" 2>/dev/null
  log "已取得认证 URL 并记录到 ${URL_FILE}"
  ensure_window "${TOKEN_URL}"
else
  log "未取到 token URL，退回根地址"
  rm -f "${URL_FILE}"
  ensure_window "${URL}"
fi

release_start_lock
trap - EXIT INT TERM
ensure_tray
exit 0
