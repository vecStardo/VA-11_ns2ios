# 更新日志 / Changelog

版本号规则：`MAJOR.MINOR.PATCH`（语义化）。构建号 `CFBundleVersion` = 当前 git 提交数（单调递增）。
版本源头：`va11mobile/VERSION`（出包时 `build.sh` 读取，可用 `DM_VERSION=` 覆盖）。

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
