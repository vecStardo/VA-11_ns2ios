#!/bin/bash
# 语言探针：把游戏 Settings/Settings.json 的 Language 写成指定下标后重启 App，等固定秒数截图。
# 用途：确定 VA-11 汉化补丁（三种语言按钮：eng_button_inst / jp_button_inst / cn_button_inst）的文本语言下标。
# 用法：./tools/lang_probe.sh <Language 下标> [等待秒数] [模拟器 UDID]
# Language probe: write the given index into the game's Settings/Settings.json Language, relaunch the App and capture a
# screenshot after a fixed delay. Used to find the text-language index of the CN patch (the game data carries three
# language buttons: eng_button_inst / jp_button_inst / cn_button_inst).
# Usage: ./tools/lang_probe.sh <Language index> [wait seconds] [simulator UDID]
set -euo pipefail
IDX=${1:?Language index required}
WAIT=${2:-130}
DEV=${3:-$(xcrun simctl list devices booted | awk -F'[()]' '/iPhone/{print $2; exit}')}
HERE=$(cd "$(dirname "$0")" && pwd)
APP=$HERE/../iosapp
B=local.va11.mobile
C=$(xcrun simctl get_app_container "$DEV" "$B" data)
python3 - "$C" "$IDX" <<'PY'
import json, os, sys
C, idx = sys.argv[1], int(sys.argv[2])
p = os.path.join(C, 'Documents/save/Settings/Settings.json')
os.makedirs(os.path.dirname(p), exist_ok=True)
d = json.load(open(p)) if os.path.exists(p) else {}
d['Language'] = idx
json.dump(d, open(p, 'w'), indent=4)
print(f'Settings.json Language -> {idx}')
PY
xcrun simctl terminate "$DEV" "$B" 2>/dev/null || true
SIMCTL_CHILD_DM_TEST_TAP_REPEAT="55:6:0.338,0.76;130:8:0.5,0.5" \
  xcrun simctl launch --terminate-running-process "$DEV" "$B" >/dev/null
sleep "$WAIT"
OUT="$(cd "$APP/out" && pwd)/lang_probe_$IDX.png"
xcrun simctl io "$DEV" screenshot "$OUT" >/dev/null 2>&1 || true
echo "screenshot: $OUT"
