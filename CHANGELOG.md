# 更新日志 / Changelog

版本号规则：`MAJOR.MINOR.PATCH`（语义化）。构建号 `CFBundleVersion` = 当前 git 提交数（单调递增）。
版本源头：`va11mobile/VERSION`（出包时 `build.sh` 读取，可用 `DM_VERSION=` 覆盖）。

## v1.1.0 — 2026-10-19 · HD 震动（小版本）

### 新增

- **HD 震动**（标题 / 暂停菜单 → 设置 → HD 振动 / HD Rumble）：接通 `nn::hid` 的震动面
  （`IsVibrationPermitted` / `GetVibrationDeviceHandles` / `InitializeVibrationDevice` /
  `GetVibrationDeviceInfo` / `SendVibrationValue`）到 iOS 触感（`front_haptic`，
  UIImpactFeedbackGenerator 轻/中/重 + 强度 0.30–1.00，Mac 宿主为空实现）；
- 按游戏语义做脉冲去重：GM runner 在一次震动期间每帧重复发同一振幅、停止时发 0，
  宿主只在「距上一次非零值 > 120 ms」时触发一次触感，避免每帧连震；
- 手柄变体覆盖：全键 / 掌机 / 双手柄给左、右 2 个非零句柄，单 Joy-Con 给 1 个。

### 验证

- iOS 模拟器（VA11-User，`DM_OPMODE=0` 掌机）：标题 → 设置 → HD 振动（软 → 硬），
  `Documents/boot.txt` 出现 `[hid-vib] 首次震动：句柄=0x1002000 振幅=1.00` 与
  `[haptic] 前端震动：振幅 1.00 → 重 档，强度 1.00`，且一次点击只出现一条 `[haptic]`（去重生效）；
- 真机（LiveContainer）：用户在设置页实测 HD 振动，确认通过；
- arm64 无签名出包 `Va11IOS-1.1.0-unsigned.ipa`（build 132 = 本版本提交数）
  结构校验 0 项红，ad-hoc 自签演练通过。

### 说明

- 原版语义下「硬 → OFF」那一次振幅为 0、不会震，属预期行为；
- 目前一次脉冲一次 impact，不是 0.2 s 连续震动；后续如需更接近 Switch HD 震动，
  可评估 CoreHaptics 连续事件并保留 UIImpactFeedbackGenerator 兜底。

## v1.0.0 — 2026-10-20 · 首个正式版本（初版移植）

第一个可对外发布的版本：VA-11 HALL-A（Nintendo Switch 版）在 iPhone / iPad 上原生运行，
无签名 IPA，自签 / LiveContainer 安装。

### 已实现

- **宿主移植**：沿用 d2r-mobile 血统——程序改写器（`patch_nso.py`）+ HLE 系统服务接管
  （文件/输入/音频/时间/账号/错误对话框）+ EGL→EAGL 图形直出；
- **无签名出包流水线**：内嵌段 → xcodebuild → Payload → `.ipa` → 结构校验（0 项红）；
- **台词系统**：Switch 版台词在 romfs 的 `scripts/<lang>/*.ini`；App 内置 `eng/chn/jp`，
  首次启动解到 `Documents/save/<lang>/`，并用补丁版 `game.win` 同步加载（修 day0 黑屏）；
- **中英双语**：两个默认语言数据变体 `game_patched_EN.win` / `game_patched_CN.win`
  （Switch 版 LANGUAGE SELECT 默认自动跳过，故用数据变体定默认语言）；
- **音频**：AVAudioSession Playback/48 kHz；修复「缓冲声明 6400 字节但只填前 3200 字节」
  导致的半速/不连续爆音（自适应按前半播放）；
- **存读档**：事务式存档（工作目录 + 原子换入），真机验证读写正常；
- **触摸**：整组触摸推送 + 帧同步点击，点标题/菜单/对话推进均可。

### 已验证（模拟器 + 真机 LiveContainer）

安装启动 / 标题 / 语言选择 / 新游戏 / 酒吧场景 / 多段对话（英中）/ 存读档 / 音频正常。

### 已知限制

- **完整游玩未验证**：调酒小游戏、多章节流程到结局、设置项全量、长时间稳定性尚未系统测试；
- 需要用户自备 Switch 正版游戏的 `game.win`（约 520 MB）与 romfs 台词；
- 外部「1.0.1 汉化补丁」与本移植使用的 1.0.0 本体不匹配，未采用（中文用本体自带 `chn`）；
- 模拟器 ~27 FPS、真机 ~30 FPS——游戏本身锁 30 FPS，属正常，不需要追 60。

### 合规

仓库不含任何游戏文件或密钥（`game.win` 即完整游戏数据包）。发布边界见 `RELEASE.zh-CN.md`。
