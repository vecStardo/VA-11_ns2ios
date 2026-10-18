#!/bin/sh
# 给 game.win 打「台词同步加载」补丁（需要 UndertaleModTool CLI）。
# 用法：tools/romfs_patch/apply_patch.sh <原始 game.win> <输出 game_patched.win> [cn]
#   第三个参数给 cn 时，额外把默认语言固定成简体中文（否则沿用游戏原本的自动判断）
# 环境变量：UTMT_CLI=UndertaleModCli 可执行文件路径（默认 <work>/out/utmt/app/UndertaleModCli；
#          <work> = VA11_WORK，缺省为与仓库同级的 work/ 目录）
set -eu
GAME=${1:?原始 game.win}
OUT=${2:?输出路径}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
WORKDIR=${VA11_WORK:-$(cd "$ROOT/.." && pwd)/work}
UTMT=${UTMT_CLI:-"$WORKDIR/out/utmt/app/UndertaleModCli"}
[ -x "$UTMT" ] || { echo "🔴 找不到 UndertaleModCli：$UTMT"; exit 1; }
LANG=${3:-}
TMP="$OUT.tmp"
"$UTMT" replace "$GAME" -c "gml_Object_async_init_Step_0=$HERE/async_init_step_host.gml" -o "$TMP"
if [ "$LANG" = "cn" ]; then
  "$UTMT" replace "$TMP" -c "gml_Object_lang_select_Create_0=$HERE/lang_cn_default.gml" -o "$OUT"
  rm -f "$TMP"
else
  mv "$TMP" "$OUT"
fi
echo "✅ 已生成 $OUT"
