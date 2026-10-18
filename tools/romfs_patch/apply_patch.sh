#!/bin/sh
# 给 game.win 打「台词同步加载」补丁（需要 UndertaleModTool CLI）。
# 用法：tools/romfs_patch/apply_patch.sh <原始 game.win> <输出 game_patched.win>
# 环境变量：UTMT_CLI=UndertaleModCli 可执行文件路径（默认 out/utmt/app/UndertaleModCli）
set -eu
GAME=${1:?原始 game.win}
OUT=${2:?输出路径}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
UTMT=${UTMT_CLI:-"$ROOT/out/utmt/app/UndertaleModCli"}
[ -x "$UTMT" ] || { echo "🔴 找不到 UndertaleModCli：$UTMT"; exit 1; }
"$UTMT" replace "$GAME" -c "gml_Object_async_init_Step_0=$HERE/async_init_step_host.gml" -o "$OUT"
echo "✅ 已生成 $OUT"
