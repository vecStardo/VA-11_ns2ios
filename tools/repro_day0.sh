#!/bin/bash
# 确定性复现「新游戏 → 第一天对话框 → textbox_loadbox 报错/黑屏」
# Deterministic reproduction of "New Game → day0 dialog → textbox_loadbox error / black screen".
#
# 用法 / usage:  tools/repro_day0.sh [等待秒数]
# 前提 / needs: 模拟器 VA11-User 已安装本仓库构建的 Va11IOS.app，且 save/game.win 是原版英文数据。
#              simulator VA11-User with this repo's Va11IOS.app installed and the original English game.win in save/.
#
# 关键点：菜单的默认高亮是「Load」，所以要对「New Game」位置连点 4 次（第一次开菜单，后几次才落到项上）。
# Key: the menu highlights Load by default, so tap the New Game spot four times (the first opens the menu).
set -u
DEV=${DM_SIM_DEV:-FFA0AB72-456E-4FC8-BC5D-47C728D01B6C}
BUNDLE=local.va11.mobile
WAIT=${1:-75}
APP="$HOME/Project/VA-11_ios/va11mobile/iosapp/Gen/dd_sim/Build/Products/Debug-iphonesimulator/Va11IOS.app"
CONT=$(xcrun simctl get_app_container "$DEV" "$BUNDLE" data 2>/dev/null) || { echo "app 未安装 / app not installed"; exit 1; }

xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1
rm -f "$CONT/Documents/boot.txt"

STEPS='at:20000;click:0.37,0.75;wait:4000;click:0.37,0.75;wait:4000;click:0.37,0.76;wait:5000;click:0.37,0.74;wait:6000;kbdrep:40,20,3500,160'
SIMCTL_CHILD_DM_LANG=${DM_LANG:-en-US} SIMCTL_CHILD_DM_TEST_STEP="$STEPS" \
  xcrun simctl launch --terminate-running-process "$DEV" "$BUNDLE" >/dev/null
sleep "$WAIT"

echo "--- 结果 / result ---"
echo "GM 报错数 / errors: $(grep -c 'ERROR in' "$CONT/Documents/boot.txt")"
echo "day0 对话框栈 / day0 stack: $(grep -c dialog_control "$CONT/Documents/boot.txt")"
grep -A6 "ERROR in" "$CONT/Documents/boot.txt" | head -8
echo "--- 日志 / log: $CONT/Documents/boot.txt ---"
