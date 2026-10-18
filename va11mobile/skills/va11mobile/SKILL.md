---
name: va11mobile
description: Build, patch, install and verify the VA-11 HALL-A (Cyberpunk Bartender Action) Nintendo Switch → iPhone/iPad port in this repository, end to end, from the user's own Switch game files. Use when the user asks to build / 复刻 / 编译 / 出包 / 安装 / 移植 VA-11 HALL-A on iOS, when they bring a `game.win`, NSP/romfs or a Switch save, or when they report the port's known failure modes (day0 black screen, distorted audio, no language option).
---

# VA-11 HALL-A · iOS 移植：构建、安装、验证

这个仓库把**用户自己拥有的 Switch 版 VA-11 HALL-A**（GameMaker 运行时 + `game.win` 数据包）跑在
iPhone / iPad 上：无签名 IPA，自签 / LiveContainer 安装。宿主代码来自 d2r-mobile 的血统，
在 `va11mobile/dm/host/`，Graphcis 走 EGL→EAGL，HLE 接管文件/输入/音频/时间/账号等服务。

**本移植目前是「初步完成」**：已验证安装启动、进新游戏、酒吧场景、多段对话、存读档、中英双语、音频；
**完整游玩（调酒流程、多章节到结局、设置项全量）尚未验证**。不要把「能进游戏」当成「已验证通关」。

## 铁律（先读）

- **用户必须自己拥有游戏**。只用用户提供的文件（`game.win`、romfs、存档）；绝不下载/附带游戏本体、
  汉化补丁、密钥或别人打包的 IPA。本仓库**不含任何游戏文件**，也不要提交。
- `prod.keys`、`title.keys`、`*.keys` 一律**不入库**（`.gitignore` 已挡）。
- 产物（`Gen/`、`out/`、`Resources/dm/`、`dmhost_m3`、`*.pcm`）不入库。
- 无签名 IPA 只给用户自己的设备用；不要公开分发含游戏内容的包。

## 交付物长什么样

```
Va11IOS-unsigned.ipa            # 无签名，bundle local.va11.mobile，最低 iOS 16
game_patched_EN.win             # 打过「台词加载补丁」的英文默认数据（*必需*）
game_patched_CN.win             # 同上，简体中文默认（可选）
eng/ chn/ jp/                   # romfs/scripts/<lang> 台词（已内置进 IPA，首次启动自动解出）
```

用户侧安装：IPA → 自签/LiveContainer；`game_patched_*.win` 改名 `game.win` 放进 App 的
`Documents/save/`；启动。

## 步骤

### 1. 准备游戏数据（用户提供）

- 需要 Switch 版 **v1.0.0 英文本体**的 `game.win`（`romfs/game.win`，约 520 MB）；
- 台词**不在** `game.win` 里，在 romfs 的 `scripts/<lang>/*.ini`（`eng`/`chn`/`jp`/…）。
  用 Ryujinx「提取 RomFS」或 hactool 导出 `scripts/` 目录；
  `nsz` 只能解 NSP/NCZ 容器，**不能**导出 romfs 文件树。

### 2. 给 `game.win` 打补丁（必需）

```sh
# 英文默认
tools/romfs_patch/apply_patch.sh <原版 game.win> game_patched_EN.win
# 中文默认（额外固定默认语言为简体中文）
tools/romfs_patch/apply_patch.sh <原版 game.win> game_patched_CN.win cn
```

补丁做什么：把 `gml_Object_async_init_Step_0` 换成**同步从 `host:/<lang>/*.ini` 读台词**的版本。
原因见下面「坑 1」。

### 3. 出包

```sh
# 先按 README「构建与出包」准备改写后的模块（patch_nso.py → ~/va11-work/patched）
cd va11mobile/iosapp
DM_PATCHED=~/va11-work/patched ./build.sh
# 产物：out/Va11IOS-unsigned.ipa（脚本会做结构校验，要求 0 项红）
```

台词文本会在出包时从 `赛博朋克酒保行动 …/romfs/scripts/{eng,chn,jp}` 打进 `Resources/dm/`，
App 首次启动复制到 `Documents/save/<lang>/`（`seed_dialog_texts()`）。

### 4. 验证清单（按顺序看 `Documents/boot.txt`）

1. `[boot] game.win: 在` + `SHELL-OK`；
2. `[boot] 音频会话：类别=AVAudioSessionCategoryPlayback 采样率=48000 Hz`；
3. `[boot] 解出内置台词：eng/chn/jp`（首次启动）；
4. `fs open OK host:/<lang>/*.ini` 出现几十次（台词加载）；
5. `ERROR in` 计数 = 0；
6. `audio 统计`：追加 ≈57 次/秒、无数字静音、欠载 0；
7. `渲染统计`：swap 次数 ≈ FPS（模拟器 ~27、真机 ~30，游戏本身锁 30）；
8. 手动：语言选择 → 新游戏 → 酒吧场景 → 点击推进多段对话 → 存/读档。

## 坑与经验（按踩坑顺序）

### 坑 1 · day0 黑屏：台词在 romfs，不在 game.win

Switch 版台词是 `scripts/<lang>/*.ini`，由 `async_init` 用 `buffer_load_async` 加载进
`global.dialog_files_texts`。移植的 GameMaker 文件接口**读不到 romfs 相对路径**，map 永远为空
→ `textbox_loadbox` 拿不到文本 → day0 黑屏。

修法：App 内置 `eng/chn/jp`，首次启动复制到 `Documents/save/`（`host:` 可读），
并把 `async_init_Step_0` 换成同步读 `host:/<name>` 的版本（`tools/romfs_patch/`）。
UTMT 反编译（`out/utmt/gml_all/`）是定位这类 GML 行为的最快途径。

### 坑 2 · 音频「爆」：缓冲声明 6400 字节，实际只填前 3200

游戏 `SetAudioOutBufferInfo` 声明 6400 字节（1600 帧），但每次 `Append` 只写入**前 3200 字节**，
后半是未写入的旧内存（数字 0）。按 6400 播放 = 一半有声一半静音，且释放周期翻倍（30 次/秒）
→ 产出只有实时的一半 → 不连续爆音。

修法（`hle_audio.c`）：追加时若「后半段整段为 0、前半段有信号」，按前半 3200 字节入队。
修复后追加 ≈57 次/秒、无数字静音段、接缝与全段一致。**纯音干净不代表性链路没问题**——
它绕过游戏缓冲；必须 dump 实际 PCM（`DM_AUDIO_OUT_DUMP` / `DM_AUDIO_DUMP`）做统计。

### 坑 3 · 语言选项「找不到」

语言在启动的 `LANGUAGE SELECT` 房间（`eng_button`/`jp_button`/`cn_button`），Switch 版会按系统语言
自动决定并跳过；Settings 里没有。给两个默认语言数据变体是最省事的方案。

### 坑 4 · 汉化补丁版本不匹配

外部「1.0.1 汉化补丁」与 1.0.0 本体不是同一构建；本移植直接用本体 romfs 的 `chn` 台词，
不要混用补丁的 `game.win`。

### 坑 5 · 不要为音频去追 60 FPS

这游戏**按设计锁 30 FPS**：数据里 `GMS2FPS=30`，PC 版在性能溢出的机器上同样锁 30。
所以模拟器 ~27 FPS / 真机 ~30 FPS 是正常范围，**不需要优化到 60**。
`DM_FRAME_CAP` 的 30/60 对照实验也证明音频数字静音比例与帧率无关——音频异常真因是坑 2 的缓冲语义。
把精力放在**缓冲/ABI/文件路径**上，而不是帧率。

### 坑 6 · 无签名出包与真机

`build.sh` 会做 `__DM*W` 段校验 + ad-hoc 自签演练，要求「0 项红」；LiveContainer 下宿主映像
按内嵌节定位（`dm_host_image()`），不要用 `_NSGetMachExecuteHeader` 判断段是否存在。

## 排障入口

- 日志：App `Documents/boot.txt`（把整个文件发回来即可）；
- 音频：`DM_AUDIO_OUT_DUMP`（交给声卡前）、`DM_AUDIO_DUMP`（游戏追加时）、`DM_AUDIO_TESTTONE=1`（440 Hz 自检音）；
- 渲染：`渲染统计`（FPS/present 耗时）；
- 台词：`fs open OK host:/<lang>/…` 次数；
- 详细调查记录：`va11mobile/verify/INPUT-DIAG.zh-CN.md`（几十轮踩坑的原始证据与结论）。
