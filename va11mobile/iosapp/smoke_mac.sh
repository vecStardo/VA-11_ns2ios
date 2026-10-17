#!/bin/bash
# Va11IOS 壳的 Mac 冒烟：同一份工程按「Designed for iPad」目标在 Apple 芯片 Mac 上构建（ad-hoc 签），
# 包 Wrapper 启动，拉回 Documents/boot.txt，认 SHELL-OK / SHELL-RED。
# 依据 dm/ios/tools/smoke_mac.sh：直接 open 设备产物报 incorrect executable format，须以 Designed for iPad 目标构建；
# open 还须包成 <名>.app/Wrapper/Va11IOS.app + WrappedBundle 软链。
# Va11IOS shell Mac smoke: build the same project for the "Designed for iPad" destination on an Apple silicon
# Mac (ad-hoc signed), wrap and launch, pull back Documents/boot.txt, expect SHELL-OK / SHELL-RED.
set -uo pipefail
cd "$(dirname "$0")"
HERE=$(pwd); DD=$HERE/Gen/dd_mac; RUN=$HERE/out; mkdir -p "$RUN"
t(){ echo "[$(date +%T)] $*"; }
B=local.va11.mobile

# iOS App 在 Mac 上要有真实开发签名（ad-hoc 报 -10673 拒启）：取钥匙串里第一张有效的 Apple Development 证书
# iOS apps on Mac need a real development signature (ad-hoc gets refused with -10673): use the first valid Apple Development cert
IDENT=$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')
[ -n "$IDENT" ] || { t "🔴 钥匙串没有有效的 Apple Development 证书"; exit 1; } # shellcheck disable=SC2016
t "构建 Designed for iPad 变体（签名: ${IDENT}）"
xcodebuild -project Va11IOS.xcodeproj -scheme Va11IOS -configuration Release \
  -destination 'platform=macOS,arch=arm64,variant=Designed for iPad' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENT" DEVELOPMENT_TEAM=$(sed -n 's/.*(\([A-Z0-9]\{10\}\))"/\1/p' <<< "$IDENT") \
  build > Gen/build_mac.log 2>&1 || { t "🔴 构建失败（Gen/build_mac.log）"; grep -E "error:" Gen/build_mac.log | head -5; exit 1; }
APP=$(ls -d "$DD/Build/Products"/*/Va11IOS.app 2>/dev/null | head -1)
[ -d "$APP" ] || { t "🔴 产物不在 Gen/dd_mac 下"; exit 1; }

t "包 Wrapper 并启动"
W=$RUN/Va11MacSmoke.app; rm -rf "$W"; mkdir -p "$W/Wrapper" && cp -cR "$APP" "$W/Wrapper/" && ln -s Wrapper/Va11IOS.app "$W/WrappedBundle"
# 收掉旧实例：同 bundle id 只能有一个实例（再 open 报 -10670/-10673）
for p in $(ps -axo pid=,comm= | awk '{ pid=$1; $1=""; sub(/^ /,""); if ($0 ~ /Va11IOS\.app\/Va11IOS$/) print pid }'); do kill -9 "$p" 2>/dev/null; done; sleep 1
open -n "$W" || { t "🔴 open 失败"; exit 1; }

t "等待自检结果（最多 40 秒）"
C=""
for i in $(seq 1 40); do
  C=$(ls -d "$HOME/Library/Containers/$B/Data" 2>/dev/null) && [ -f "$C/Documents/boot.txt" ] && grep -q "SHELL DONE" "$C/Documents/boot.txt" 2>/dev/null && break
  sleep 1
done
if [ -n "$C" ] && [ -f "$C/Documents/boot.txt" ]; then
  cp "$C/Documents/boot.txt" "$RUN/boot_mac.txt"; cat "$RUN/boot_mac.txt"
  grep -q "SHELL-OK" "$RUN/boot_mac.txt" && V=OK || V=RED
else
  V=RED; echo "【红】40 秒内没等到 SHELL DONE（container=${C:-无}）"
fi
for p in $(ps -axo pid=,comm= | awk '{ pid=$1; $1=""; sub(/^ /,""); if ($0 ~ /Va11IOS\.app\/Va11IOS$/) print pid }'); do kill -9 "$p" 2>/dev/null; done
echo "SMOKE-MAC ${V}（报告 $RUN/boot_mac.txt）"
[ "$V" = OK ]
