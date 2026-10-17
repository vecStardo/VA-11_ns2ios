#!/bin/bash
# Va11IOS 无签名出包：改写映像内嵌 → xcodebuild（CODE_SIGNING_ALLOWED=NO）→ Payload → .ipa → 结构校验。
# 产物与校验报告在 out/（不进仓）。用法：./build.sh [--gen-only]
# 用法示例：DM_PATCHED=~/va11-work/patched ./build.sh
# Va11IOS unsigned packaging: embed rewritten images -> xcodebuild (CODE_SIGNING_ALLOWED=NO) -> Payload ->
# .ipa -> structural verification. Artifacts and the report live in out/ (not committed). Usage: ./build.sh
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
PATCHED=${DM_PATCHED:-$HOME/va11-work/patched}
OUT=${DM_OUT:-$HERE/out}
MODS=${DM_MODS:-"main sdk subsdk0 subsdk1"}
t(){ echo "[$(date +%T)] $*"; }
[ -d "$PATCHED" ] || { t "🔴 改写产物目录不在: ${PATCHED}（DM_PATCHED=... 指一下）"; exit 1; }
for m in $MODS; do
  [ -f "$PATCHED/$m.patched.bin" ] && [ -f "$PATCHED/$m.fixups.tsv" ] || { t "🔴 缺 ${m} 的改写产物（.patched.bin/.fixups.tsv）"; exit 1; }
done

# 1) 生成内嵌汇编与链接参数（dm/ios/tools/gen_embed.py，与 d2r-mobile 同一份）
t "生成内嵌汇编 Gen/embed.S（模块: ${MODS}）"
mkdir -p Gen Resources/dm
rm -f Gen/embed.S Resources/dm/*.tsv
# iOS 不允许改代码页：宿主在 Mac 上装载期做的两条 udf→RET 补丁，在这里落到内嵌用的产物副本上（见 patch_product_ios.py）
# iOS forbids writing code pages: the two udf->RET patches the Mac host applies at load time are applied here to the
# copy of the build output that gets embedded (see patch_product_ios.py)
# 暂存目录放在 Gen/ 下：embed.S 里记的是绝对路径，xcodebuild 是下一步才跑，目录不能随脚本退出被删
# The staging directory lives under Gen/: embed.S records absolute paths and xcodebuild runs in a later step, so it
# must not vanish when the script exits
STAGE=$HERE/Gen/product_ios
rm -rf "$STAGE"
t "出包期补丁 → 内嵌产物副本（Gen/product_ios）"
python3 patch_product_ios.py "$PATCHED" "$STAGE" || { t "🔴 产物补丁失败"; exit 1; }
python3 ../dm/ios/tools/gen_embed.py "$STAGE" Gen/embed.S $MODS > Gen/segprot_flags.txt
# 宿主源文件清单 / 头路径 / 宏 / 框架：从 dm/host/Makefile 展开取，增删宿主文件不用改这份工程
# Host source list / header paths / macros / frameworks: taken from the expanded dm/host/Makefile, so adding or
# removing host files needs no change to this project
t "生成宿主构建输入 Gen/ios_build.xcconfig（gen_build_ios.py）"
python3 gen_build_ios.py ../dm/host Gen > Gen/ios_build.xcconfig || { t "🔴 gen_build_ios 失败"; exit 1; }
{ echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $(cat Gen/segprot_flags.txt)"; cat Gen/ios_build.xcconfig; } > Gen/dm.xcconfig
for m in $MODS; do cp "$PATCHED/$m.fixups.tsv" "$PATCHED/$m.gates.tsv" Resources/dm/; done
[ -f "$PATCHED/main.cuts.tsv" ] && cp "$PATCHED/main.cuts.tsv" Resources/dm/ || true
[ "${1:-}" = "--gen-only" ] && { t "生成完成（--gen-only）"; exit 0; }

# 2) 生成工程并构建（无签名，真机 arm64）
t "xcodegen 生成工程"
xcodegen generate -q || { t "🔴 xcodegen 失败"; exit 1; }
t "xcodebuild（无签名 arm64，Release）"
DD=$HERE/Gen/dd
xcodebuild -project Va11IOS.xcodeproj -scheme Va11IOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  build > Gen/build.log 2>&1 || { t "🔴 构建失败（Gen/build.log）"; grep -E "error:" Gen/build.log | head -5; exit 1; }
APP="$DD/Build/Products/Release-iphoneos/Va11IOS.app"
[ -d "$APP" ] || { t "🔴 产物不在：$APP"; exit 1; }

# 3) 打包 .ipa（Payload/Va11IOS.app → zip）
t "打包 Payload → ipa"
STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload" && cp -R "$APP" "$STAGE/Payload/"
mkdir -p "$OUT"; rm -f "$OUT"/*.ipa
IPA="$OUT/Va11IOS-unsigned.ipa"
(cd "$STAGE" && zip -qyr "$IPA" Payload)
unzip -t "$IPA" > /dev/null || { t "🔴 ipa zip 完整性失败"; exit 1; }

# 4) 结构校验
t "结构校验"
EXE="$STAGE/Payload/Va11IOS.app/Va11IOS"
R="$OUT/verify.txt"; : > "$R"
say(){ echo "$*" | tee -a "$R"; }
say "== Va11IOS-unsigned.ipa 结构校验 $(date '+%F %T')"
say "ipa: $(du -h "$IPA" | cut -f1)  exe: $(du -h "$EXE" | cut -f1)"
# 4.1 Mach-O 头 / 架构
file "$EXE" | sed 's/^/  /' | sed 1!d >> "$R"; say "  file: $(grep -o 'Mach-O 64-bit executable arm64' <<< "$(file -b "$EXE")" || echo '✗ 非 arm64 可执行')"
# 4.2 minOS 与代码签名槽（无签名 = 不该有 LC_CODE_SIGNATURE）
MINOS=$(otool -l "$EXE" | awk '/LC_BUILD_VERSION/{f=1} f&&/  minos/{print $2; exit}')
NSIG=$(otool -l "$EXE" | grep -c LC_CODE_SIGNATURE || true)
say "  minos: ${MINOS:-未知}   LC_CODE_SIGNATURE: ${NSIG}（无签名出包应为 0）"
[ -n "$MINOS" ] && [ "$NSIG" = 0 ] || { say "  🔴 minOS/签名槽不符"; }
# 4.3 内嵌段（__DM<名>W 与 __dm<名>x0/x1）
for m in $MODS; do
  # otool -l 里 segname 出现两次：LC_SEGMENT_64 一条 + 段内 __img 节一条 = 2 才是「段在且节在」
  # otool -l lists segname twice: one for LC_SEGMENT_64, one for the __img section inside = 2 means both present
  NSEG=$(otool -l "$EXE" | awk -v s="__DM${m}W" '$1=="segname"&&$2==s{n++} END{print n+0}')
  say "  段 __DM${m}W: ${NSEG}（应为 2 = 段 + __img 节）"; [ "$NSEG" = 2 ] || say "  🔴 缺 __DM${m}W 或其 __img 节"
done
# 4.4 codesign 视角：应报完全未签名
CS=$(codesign -dv "$EXE" 2>&1 | head -3 | tr '\n' ' ' || true)   # 未签名时 codesign 本身报错退出，取其文案即可 | codesign errors out on unsigned input; capture the message only
case "$CS" in *"not signed at all"*) say "  codesign: 完全未签名 ✓";; *) say "  codesign: $CS"; say "  🔴 不是未签名状态";; esac
# 4.5 Info.plist 关键键
P="$STAGE/Payload/Va11IOS.app/Info.plist"
plutil -lint "$P" | sed 's/^/  /' >> "$R"
BID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$P")
BEX=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$P")
MOV=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$P")
say "  bundle: $BID  exe: $BEX  minOS: $MOV"
[ "$BEX" = Va11IOS ] || say "  🔴 CFBundleExecutable 与可执行名不一致"
# 4.6 自签可装性演练（在副本上 ad-hoc 签，等价自签工具对结构的最低要求；不出进 ipa）
cp -R "$STAGE/Payload/Va11IOS.app" "$STAGE/rs.app"
if codesign -f -s - "$STAGE/rs.app" > /dev/null 2>&1 && codesign -v --verify "$STAGE/rs.app" > /dev/null 2>&1; then
  say "  自签演练: ad-hoc 签名 + 校验通过 ✓（结构可被自签工具补签）"
else
  say "  🔴 自签演练失败：结构或段布局不被 codesign 接受"
fi
say "结论: $(grep -c '🔴' "$R") 项红（0 = 通过）"
t "完成: ${IPA}（校验报告 ${R}）"
cat "$R"
