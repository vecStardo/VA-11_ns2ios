#!/bin/bash
# Va11IOS 模拟器冒烟：构建 Simulator 变体 → 装机 → 往 App 容器里放游戏数据（game.win，APFS 克隆不占空间）
# → 启动 → 等宿主日志出现「Entering main loop.」→ 截图 → 判定 GAME-OK / GAME-RED。
# 这条冒烟证明的是「宿主核心在 iOS arm64 上跑起来、EGL→EAGL 出图、触摸/音频/文件系统接上、原版 game.win 加载进主循环」；
# 真机另行装机（无签名 ipa 见 build.sh）。
# 环境变量：DM_SIM_DEV（模拟器 UDID，缺省取第一台可用 iPhone）、DM_GAME_WIN（game.win 路径）、DM_SIM_TIMEOUT（秒，缺省 120）。
# Va11IOS simulator smoke: build the Simulator variant -> install -> put the game data (game.win, APFS-cloned, no extra
# space) into the App container -> launch -> wait for "Entering main loop." in the host log -> screenshot -> verdict
# GAME-OK / GAME-RED.
# What this proves: the host core runs on iOS arm64, EGL->EAGL presents, touch/audio/filesystem are hooked up, and the
# original game.win loads through to the main loop. Real devices are installed separately (unsigned ipa from build.sh).
# Env: DM_SIM_DEV (simulator UDID, defaults to the first available iPhone), DM_GAME_WIN (game.win path),
#      DM_SIM_TIMEOUT (seconds, default 120).
set -uo pipefail
cd "$(dirname "$0")"
HERE=$(pwd); DD=$HERE/Gen/dd_sim; RUN=$HERE/out; mkdir -p "$RUN"
t(){ echo "[$(date +%T)] $*"; }
B=local.va11.mobile
DEV=${DM_SIM_DEV:-$(xcrun simctl list devices available | awk -F'[()]' '/iPhone/{print $2; exit}')}
[ -n "$DEV" ] || { t "🔴 没有可用的 iOS 模拟器"; exit 1; }
GAME_WIN=${DM_GAME_WIN:-"$HERE/../../赛博朋克酒保行动 Cyberpunk Bartender Action/1.0.0汉化补丁/010086500D3C8000/romfs/game.win"}
[ -f "$GAME_WIN" ] || { t "🔴 找不到 game.win：$GAME_WIN（DM_GAME_WIN=... 指一下）"; exit 1; }
TIMEOUT=${DM_SIM_TIMEOUT:-120}

t "构建 Simulator 变体（arm64；客体代码只有 arm64）"
xcodebuild -project Va11IOS.xcodeproj -scheme Va11IOS -configuration Debug \
  -destination "id=${DEV}" -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  build > Gen/build_sim.log 2>&1 || { t "🔴 构建失败（Gen/build_sim.log）"; grep -E "error:" Gen/build_sim.log | head -5; exit 1; }
APP="$DD/Build/Products/Debug-iphonesimulator/Va11IOS.app"
[ -d "$APP" ] || { t "🔴 产物不在：$APP"; exit 1; }

t "启动模拟器 $DEV 并装机"
xcrun simctl bootstatus "$DEV" -b > /dev/null 2>&1
xcrun simctl install "$DEV" "$APP" || { t "🔴 装机失败"; exit 1; }
C=$(xcrun simctl get_app_container "$DEV" "$B" data) || { t "🔴 取不到 App 容器"; exit 1; }
t "准备游戏数据（$C/Documents/save）"
mkdir -p "$C/Documents/save"
if [ ! -f "$C/Documents/save/game.win" ]; then
  cp -c "$GAME_WIN" "$C/Documents/save/game.win" 2>/dev/null || cp "$GAME_WIN" "$C/Documents/save/game.win"   # APFS 克隆；跨卷回退普通拷贝 | APFS clone, plain copy across volumes
  printf 'False' > "$C/Documents/save/preselected_user"
fi
rm -f "$C/Documents/boot.txt"

t "启动并等待主循环（最多 ${TIMEOUT} 秒）"
xcrun simctl launch --terminate-running-process "$DEV" "$B" || { t "🔴 启动失败"; exit 1; }
V=RED
for i in $(seq 1 "$TIMEOUT"); do
  if [ -f "$C/Documents/boot.txt" ] && grep -q "Entering main loop" "$C/Documents/boot.txt"; then V=OK; break; fi
  if [ -f "$C/Documents/boot.txt" ] && grep -qE "FATAL|dm_main 返回|【红】起客体" "$C/Documents/boot.txt"; then break; fi
  sleep 1
done
cp "$C/Documents/boot.txt" "$RUN/boot_sim.txt" 2>/dev/null
t "截图"
xcrun simctl io "$DEV" screenshot "$RUN/boot_sim.png" > /dev/null 2>&1
# 关键行摘出来（报告看这几行就够） | Pull out the key lines (these suffice in the report)
echo "--- boot_sim.txt 关键行 ---"
grep -E "EAGL 就绪|主线程预建|SHELL-|game.win:|Entering main loop|OpenAudioOut|Run_Start|存档提交|FATAL|【红】" "$RUN/boot_sim.txt" 2>/dev/null | head -12
echo "--- 结论: GAME-${V}（报告 $RUN/boot_sim.txt，截图 $RUN/boot_sim.png）"
[ "$V" = OK ]
