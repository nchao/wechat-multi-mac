#!/usr/bin/env bash
# macOS 微信多开
# 用法: wechat.sh <名字> [名字...]        生成/启动一个或多个副本
#       wechat.sh --list                 列出已有副本（给 GUI 选择列表用）
#       wechat.sh --uninstall <名字>...  卸载副本（app 移入废纸篓，数据目录默认保留）
#       wechat.sh --uninstall --purge <名字>...  连同数据目录一起移入废纸篓
#   名字 = 副本名，不含 .app（脚本自己拼），例: wechat.sh WeChat4 / wechat.sh 工作号
#   生成流程：从 WeChat.app 复制成 /Applications/<名字>.app，改 CFBundleIdentifier
#   后重签名再启动。副本已存在且 id 正确就直接启动。
set -uo pipefail

BASE_APP="/Applications/WeChat.app"
BASE_ID="com.tencent.xinWeChat"
BIN_REL="Contents/MacOS/WeChat"

# Automator / osascript 调起时不带 locale，中文参数会变乱码
export LANG="${LANG:-zh_CN.UTF-8}"
export LC_ALL="${LC_ALL:-zh_CN.UTF-8}"

# --from-file <文件>: 名字从文件读（一行一个），避开 GUI 层的引用转义问题。
# 文件首行可以是 --uninstall / --uninstall --purge，表示卸载。
if [[ "${1:-}" == "--from-file" ]]; then
  f="${2:-}"
  [[ -r "$f" ]] || { echo "读不到参数文件: $f" >&2; exit 1; }
  args=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    args+=("$line")
  done < "$f"
  set -- "${args[@]}"
fi

# 按名字推导 bundle id，规则与 ~/Library/Containers 下已有的数据目录保持一致
id_for_name() {
  if [[ "$1" =~ ^WeChat([0-9]+)$ ]]; then
    echo "${BASE_ID}${BASH_REMATCH[1]}"
  else
    echo "${BASE_ID}.$1"
  fi
}

# --list: 输出所有「微信副本」的名字（不含 .app），一行一个。
# 判定标准是含 Contents/MacOS/WeChat 可执行文件，避免把同名的其他 app 混进来。
if [[ "${1:-}" == "--list" ]]; then
  for a in /Applications/*.app; do
    [[ "$a" == "$BASE_APP" ]] && continue
    [[ -x "${a}/${BIN_REL}" ]] || continue
    b="$(basename "$a")"
    echo "${b%.app}"
  done
  exit 0
fi

# --uninstall: app 移入废纸篓（不用 rm，误删可恢复）。加 --purge 才动数据目录。
if [[ "${1:-}" == "--uninstall" ]]; then
  shift
  purge=0
  if [[ "${1:-}" == "--purge" ]]; then purge=1; shift; fi
  if [[ $# -eq 0 ]]; then
    echo "用法: $(basename "$0") --uninstall [--purge] <名字>..." >&2
    exit 1
  fi

  trash="$HOME/.Trash"
  fail=0
  for n in "$@"; do
    n="${n%.app}"
    app="/Applications/${n}.app"
    if [[ "$app" == "$BASE_APP" ]]; then
      echo "[${n}] 这是原版微信，拒绝卸载" >&2
      fail=1; continue
    fi
    if [[ ! -d "$app" ]]; then
      echo "[${n}] 不存在，跳过"
      continue
    fi
    if pgrep -f "^${app}/${BIN_REL}$" >/dev/null 2>&1; then
      echo "[${n}] 正在运行，先退出它再卸载" >&2
      fail=1; continue
    fi

    dest="${trash}/${n}.app"
    [[ -e "$dest" ]] && dest="${trash}/${n} $(date +%H.%M.%S).app"
    if mv "$app" "$dest"; then
      echo "[${n}] app 已移入废纸篓: $(basename "$dest")"
    else
      echo "[${n}] 移动失败" >&2
      fail=1; continue
    fi

    data="$HOME/Library/Containers/$(id_for_name "$n")"
    if [[ -d "$data" ]]; then
      if [[ $purge -eq 1 ]]; then
        ddest="${trash}/$(basename "$data")"
        [[ -e "$ddest" ]] && ddest="${ddest}.$(date +%H.%M.%S)"
        if mv "$data" "$ddest"; then
          echo "[${n}] 数据目录已移入废纸篓（$(du -sh "$ddest" 2>/dev/null | cut -f1)）"
        else
          echo "[${n}] 数据目录移动失败: $data" >&2
          fail=1
        fi
      else
        echo "[${n}] 数据目录保留（$(du -sh "$data" 2>/dev/null | cut -f1)）: $data"
      fi
    fi
  done

  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$LSREG" ]] && "$LSREG" -kill -r -domain local -domain user >/dev/null 2>&1
  exit $fail
fi

if [[ $# -eq 0 ]]; then
  echo "用法: $(basename "$0") <名字> [名字...]   例: $(basename "$0") WeChat2 WeChat3" >&2
  echo "      $(basename "$0") --list" >&2
  echo "      $(basename "$0") --uninstall [--purge] <名字>..." >&2
  exit 1
fi

if [[ ! -d "$BASE_APP" ]]; then
  echo "找不到 $BASE_APP" >&2
  exit 1
fi

# 不需要 sudo：/Applications 是 root:admin 且 drwxrwxr-x，当前用户在 admin 组；
# WeChat.app 及副本都归当前用户。复制 / 改 Info.plist / codesign 三步实测无需提权。
if [[ ! -w /Applications ]]; then
  echo "当前用户对 /Applications 没有写权限，需要管理员账户" >&2
  exit 1
fi

# 多个名字依次处理，单个失败不影响其余
overall=0
for name in "$@"; do

name="${name%.app}"
if [[ -z "$name" || "$name" == *"/"* || "$name" == .* ]]; then
  echo "[${name}] 名字不合法（不能为空、含 / 或以 . 开头），跳过" >&2
  overall=1; continue
fi

app="/Applications/${name}.app"
bin="${app}/${BIN_REL}"
want_id="$(id_for_name "$name")"

if [[ "$app" == "$BASE_APP" ]]; then
  echo "[${name}] 不能用原版名字 WeChat，跳过" >&2
  overall=1; continue
fi

if pgrep -f "^${bin}$" >/dev/null 2>&1; then
  echo "[${name}] 已在运行，无需处理"
  continue
fi

if [[ ! -d "$app" ]]; then
  echo "[${name}] 从 WeChat.app 复制副本..."
  cp -Rp "$BASE_APP" "$app" \
    || { echo "[${name}] 复制失败" >&2; overall=1; continue; }
fi

if [[ ! -x "$bin" ]]; then
  echo "[${name}] ${bin} 不存在，${app} 可能不是微信 app" >&2
  overall=1; continue
fi

cur_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${app}/Contents/Info.plist" 2>/dev/null)"
if [[ "$cur_id" == "$BASE_ID" || -z "$cur_id" ]]; then
  echo "[${name}] 改 bundle id: ${cur_id:-无} -> ${want_id}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${want_id}" "${app}/Contents/Info.plist" \
    || { echo "[${name}] 改 bundle id 失败" >&2; overall=1; continue; }
  echo "[${name}] 重签名（较慢，稍等）..."
  codesign --force --deep --sign - "$app" \
    || { echo "[${name}] 签名失败" >&2; overall=1; continue; }
  # 刷新 LaunchServices 注册，否则 Dock/启动台可能仍按旧 id 路由到原版窗口
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [[ -x "$LSREG" ]] && "$LSREG" -f "$app"
else
  echo "[${name}] bundle id 已是 ${cur_id}，跳过改 id 和重签名"
fi

# 校验：签名后的实际 id 必须与目标一致，否则点 Dock 还是会跳到原版
real_id="$(codesign -dv "$app" 2>&1 | sed -n 's/^Identifier=//p')"
if [[ "$real_id" != "$want_id" ]]; then
  echo "[${name}] 警告: 签名 Identifier 实际是 ${real_id:-未知}，期望 ${want_id}" >&2
  echo "[${name}] 这种状态下点 Dock 图标会激活原版窗口，需要排查" >&2
  overall=1
fi

echo "[${name}] 启动: ${app}"
nohup "$bin" >/dev/null 2>&1 &
disown

done

exit $overall
