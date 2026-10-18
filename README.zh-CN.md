# VA-11 HALL-A — Nintendo Switch → iOS 移植

把**你自己拥有的** Nintendo Switch 版《VA-11 HALL-A: Cyberpunk Bartender Action》原生跑在
iPhone / iPad 上。本仓库提供该游戏（GameMaker / Switch 构建）的 iOS 兼容层，以及无签名 `.ipa`
打包流水线。

**版本：** `v1.0.0`（首个正式版本 · 初版移植） ·
[Release](https://github.com/vecStardo/VA-11_ns2ios/releases/tag/v1.0.0) ·
[更新日志](CHANGELOG.md) · English: [README.md](README.md)

> **本仓库不包含任何游戏内容与密钥。**
> `game.win`（约 520 MB）是完整游戏数据包（GML 字节码、贴图、音频、文本），必须由你从自己拥有的
> 正版游戏中准备。见「[合规与法律](#合规与法律)」。

---

## 功能

- **原生执行 Switch 构建**：游戏的四个模块（`main`、`sdk`、`subsdk0`、`subsdk1`）被重新链接后
  直接在 Apple silicon 上运行，不使用模拟器。
- **HLE 宿主层**：接管游戏使用的 Horizon 系统服务——文件系统、输入、音频、时间、账号、错误对话框，
  该层架构来自 d2r-mobile 项目。
- **图形**：游戏的 EGL/GLES 调用在 iOS 上直接由 EAGL 承接。
- **台词系统**：Switch 版台词存放在 romfs（`scripts/<lang>/*.ini`）；App 内置 `eng`/`chn`/`jp`
  三套台词，首次启动解压到存档目录，并通过打过补丁的 `game.win` 同步加载（修复「day 0 黑屏」）。
- **两种默认语言**：`game_patched_EN.win` / `game_patched_CN.win`
  （Switch 版会按系统语言自动选择并跳过 LANGUAGE SELECT 画面）。
- **音频**：`AVAudioSession` 以 48 kHz 播放，并修复了「游戏缓冲只填一半」导致的半速/爆音问题。
- **存读档**：事务式写入（存档目录原子换入）。

## 项目状态

这是**首个正式版本，也是初版**：能启动、能玩到酒吧场景并推进对话，但**尚未完整通关验证**。

| 能力 | 状态 |
|---|---|
| 无签名 IPA 安装（iOS 16+，bundle `local.va11.mobile`） | ✅ |
| 标题 → 语言选择 → 新游戏 → 酒吧场景 | ✅ |
| 多段对话推进（英文 / 中文） | ✅ |
| 存 / 读档 | ✅ 基础读写已验证 |
| 音频（音乐 / 音效） | ✅ 已修复并验证 |
| **完整游玩**（调酒玩法、全部章节、结局、全部设置项） | ❌ **未验证** |

已在 iOS 模拟器与真机（LiveContainer）上验证。

## 环境要求

- **使用者**：iOS 16+ 的 iPhone/iPad、自签工具（Sideloadly、LiveContainer 等），以及你自己拥有的
  Switch 版游戏（`game.win` + romfs 的 `scripts/` 目录）。
- **构建者**：macOS + Xcode（建议 16+）、`xcodegen`、Python 3；改写器作用于你提供的游戏模块。

## 快速开始（使用者）

1. 用自签工具安装 `Va11IOS-<版本>-unsigned.ipa`；
2. 给你自己的 `game.win` 打台词补丁，放到 `Documents/save/game.win`：
   ```sh
   tools/romfs_patch/apply_patch.sh <你的 game.win> game_patched_EN.win      # 英文默认
   tools/romfs_patch/apply_patch.sh <你的 game.win> game_patched_CN.win cn   # 中文默认
   ```
3. 如果使用的 IPA 是干净包（Release 附件即如此，未内置台词），把 romfs 的 `eng/` 或 `chn/` 目录
   放进 `Documents/save/`；
4. 启动 App → LANGUAGE SELECT → 新游戏。

诊断日志写入 `Documents/boot.txt`，反馈问题时请附上该文件。

## 从源码构建（开发者）

```sh
# 1) 把四个游戏模块改写为 Apple silicon 可执行（输出到 ~/va11-work/patched）
DM_FOREIGN_GAME=1 DM_RULESET=native python3 va11mobile/dm/tools/patch_nso.py <exefs/main> <out> main
#    sdk / subsdk0 / subsdk1 同理

# 2) 打出无签名 IPA
cd va11mobile/iosapp
DM_PATCHED=~/va11-work/patched ./build.sh                 # 内置 eng/chn/jp 台词
DM_TEXTS_ROMFS=/nonexistent DM_PATCHED=~/va11-work/patched ./build.sh   # 干净包（不含游戏文本）
```

出包脚本会完成：内嵌映像 → `xcodebuild`（无签名、arm64）→ `Payload` → `out/Va11IOS-<版本>-unsigned.ipa`
→ 结构校验（段 / bundle / 版本号 / ad-hoc 签名演练），必须报告 **0 项红**。

## 工作目录（为什么不在仓库里）

构建工作目录默认是 `~/va11-work`（可用 `VA11_WORK=/路径` 改）。它存放解包后的游戏文件、改写后的模块
和大量调试 dump——从几百 MB 到几十 GB，并且包含游戏数据与密钥。把它**刻意放在仓库之外**，
沿用 d2r-mobile 的 `$DM_ROOT` 约定：

- 仓库保持干净、体积可控（不含游戏目录时约 200 MB），`git status` 不会碰到 500 MB 的二进制或密钥；
- 合法边界：游戏数据与密钥永远不在 git 根目录下，不可能被误提交；
- 备份/同步工具与 IDE 不会去索引、上传几十 GB 的临时 dump。

典型结构：

```
~/va11-work/
  orig/game.win      解包数据（你自己的）
  exefs/             原始游戏模块（你自己的）
  patched/           出包用的改写产物
  keys/prod.keys     你的密钥（永不进仓库）
  extract_x/         NSP 解包临时目录（可删）
```

需要换位置时设 `VA11_WORK=...`，辅助脚本与 `tools/` 都会跟随该变量。

## 仓库结构

```
README.md / README.zh-CN.md     项目说明（英文 / 中文）
CHANGELOG.md                    版本更新日志
RELEASE.zh-CN.md                发布边界（哪些内容绝不可公开分发）
va11mobile/
  VERSION                       版本号源头
  dm/host/                      HLE 宿主（macOS 宿主与 iOS App 共用）
  dm/gfx/                       NVN → Metal 图形层（VA-11 不走此路径）
  dm/tools/patch_nso.py         程序改写器
  iosapp/                       iOS App 与无签名出包流水线
  docs/LESSONS.zh-CN.md         经验与教训
  docs/PORTING.zh-CN.md         移植技术细节
  skills/va11mobile/SKILL.md    端到端构建/安装/验证操作手册（面向 Agent）
  verify/                       调查记录与验证证据
tools/                          数据工具（GML 反汇编、romfs 补丁、存档辅助）
```

## 工作原理

1. **改写器**（`va11mobile/dm/tools/patch_nso.py`）：把苹果内核下不能执行的指令（`svc`、
   `mrs cntpct`、`x18`/TLS 用法、系统计数器等）替换为调用宿主门；
2. **宿主装载与 HLE**（`va11mobile/dm/host/`）：把改写后的映像映射回来并做跨模块重定位，
   实现游戏调用的 SDK 系统服务；
3. **图形**：EGL 映射到 EAGL，游戏按原生分辨率渲染到 `CAEAGLLayer` 再等比放大到屏幕；
4. **iOS 壳**（`va11mobile/iosapp/`）：窗口、EAGL 视图、触摸注入、日志、生命周期、音频会话，
   以及无签名打包流水线。

## 游戏数据与语言

- `game.win` 是完整游戏数据包，本仓库**从不**分发；
- 台词**不在** `game.win` 中，而在 romfs 的 `scripts/<lang>/*.ini`（`eng`、`chn`、`jp` 等）；
  App 内置三套台词，首次启动解压到 `Documents/save/<lang>/`；
- Switch 版会按系统语言自动选择并跳过 LANGUAGE SELECT，因此提供两个默认语言的数据变体；
- 第三方「1.0.1 汉化补丁」与这里使用的 1.0.0 本体不匹配，未采用；中文文本来自游戏自带的 romfs `chn`。

## 验证方法

- `Documents/boot.txt` 记录启动状态、台词文件加载、音频统计与渲染帧率；
- `audio 统计` 应显示约 57 次/秒的缓冲追加、无补零缺口、欠载 0；
- `渲染统计` 在模拟器约 27 FPS、真机约 30 FPS（游戏本身锁 30 FPS，不需要也不应追求 60）。

## 已知限制

- 完整游玩未验证（调酒玩法、全部章节与结局、全部设置项、长时间稳定性）；
- 需要自备游戏数据，并对 `game.win` 做一次性补丁；
- 第三方 1.0.1 汉化补丁与 1.0.0 数据不兼容；
- 仅提供无签名 IPA，需自签安装，无法上架 App Store。

## 合规与法律

- 本仓库不含游戏文件、NSP/NSZ/XCI、`prod.keys`/`title.keys`、romfs 台词文本（已审计完整 git 历史）；
- Release 附件为**不含游戏文本的干净包**；
- 打过补丁的 `game.win`、内置台词的 IPA、导出的台词目录仅限自己设备使用，请勿公开分发，
  详见 [RELEASE.zh-CN.md](RELEASE.zh-CN.md)；
- 使用本项目的**前提是你自己拥有该游戏**。

## 致谢

- **d2r-mobile**（<https://github.com/d2r-mobile/d2r-mobile>）——本次移植的直接源头：改写器、HLE 宿主架构、
  EAGL 路径与音频流水线均来自该项目；没有它就不会有这次移植。`va11mobile/dm/` 的部分代码源自
  d2r-mobile（MIT，© 2026 jhaizhou）。
- **UndertaleModTool** —— 用于反编译 `game.win`、定位台词加载逻辑。
- GameMaker 与 Horizon 自制社区 —— 运行时与服务接口的公开文档。
- VA-11 HALL-A 版权归 Sukeban Games / Ysbryd Games 所有；本项目为非官方爱好者作品。

## 许可证

MIT，详见 [LICENSE](LICENSE)。
