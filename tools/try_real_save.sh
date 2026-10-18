#!/bin/sh
# 用一份「真机上能正常跑」的存档目录，在桌面 headless 宿主上直接读档，绕开 day0 初始化路径。
# 用法：tools/try_real_save.sh <存档目录> [秒数]
#   存档目录 = 真机/LiveContainer 里 App 的 Documents/save（含 game.win 与存档文件）
# 说明：脚本把 game.win 链接过来（不复制 500MB），再启动桌面宿主并自动点「Load」位置。
# Try a save directory taken from a working device/emulator and load it on the headless desktop host, bypassing the
# day0 initialisation path. Usage: tools/try_real_save.sh <save-dir> [seconds]
set -eu
SAVE=$1
SECS=${2:-60}
HERE=$(cd "$(dirname "$0")/.." && pwd)
VA11_WORK=${VA11_WORK:-$(cd "$(dirname "$0")/../.." && pwd)/work}
WORK=$VA11_WORK/run_real
[ -f "$SAVE/game.win" ] || { echo "🔴 $SAVE 里没有 game.win"; exit 1; }
rm -rf "$WORK"; mkdir -p "$WORK/save" "$WORK/temp"
for f in "$SAVE"/*; do
  b=$(basename "$f")
  [ "$b" = game.win ] && continue
  cp -c "$f" "$WORK/save/$b" 2>/dev/null || cp "$f" "$WORK/save/$b"
done
ln -f "$SAVE/game.win" "$WORK/save/game.win" 2>/dev/null || cp -c "$SAVE/game.win" "$WORK/save/game.win"
echo "→ 存档目录内容："; ls -la "$WORK/save" | head -12
cd "$HERE/va11mobile/dm/host"
[ -x ./dmhost_m3 ] || make dmhost_m3
EV="12000:0.5,0.5;20000:0.12,0.15;27000:0.503,0.748;31000:0.503,0.748;35000:0.503,0.748"
DM_HEADLESS=1 DM_HLE_TOLERANT=1 DM_TAP="$EV" DM_SAVE="$WORK/save" DM_TEMP="$WORK/temp" \
  ./dmhost_m3 "$VA11_WORK/patched_obs" main sdk subsdk0 subsdk1 > "$WORK/run.log" 2>&1 &
PID=$!
sleep "$SECS"; kill $PID 2>/dev/null; sleep 2; kill -9 $PID 2>/dev/null
echo "---- 关键行 ----"
grep -E "Entering main loop|非数组索引|ERROR in|fs open OK host" "$WORK/run.log" | head -20
echo "---- 日志：$WORK/run.log ----"
