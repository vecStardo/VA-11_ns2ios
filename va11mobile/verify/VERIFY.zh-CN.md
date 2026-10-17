# 内容完整性核对 · iOS（进行中）

对应 Goal todo：`[P1] 内容完整性核对：汉化文本/立绘/音乐随 game.win 生效，关键功能清单逐项验证记录`。
本文件只记录**已实际发生并可复核的证据**；没有证据的项一律写「待验证」，不按预期推断。

- 平台：iOS 26.3 模拟器（iPhone 17 Pro，arm64），Debug
- 数据源：`game.win`（1.0.0 汉化补丁，520,720,771 字节），放 App 容器 `Documents/save/`
- 原始日志：`va11mobile/iosapp/out/ios_boot_current.txt`（8,640 行，行即刷）
- 截图：`va11mobile/iosapp/out/evidence_title.png`、`evidence_ingame_saveload.png`、`evidence_touch_ui_menu.png`

## 1. game.win 数据完整性（已验证）

Android 无关；GameMaker 运行时把 `game.win` 按 chunk 逐个读出并处理，宿主日志逐条记录（`ios_boot_current.txt`）：

| chunk | 字节 | 含义 |
|---|---:|---|
| SPRT | 8,442,344 | 精灵（立绘/界面素材） |
| FONT | 867,864 | 字体（文字渲染） |
| TXTR | 13,615,704 | 纹理页（画面） |
| AUDO | 494,791,451 | 音频（音乐/音效） |
| CODE | 1,658,952 | GML 字节码 |
| SCPT/OBJT/ROOM/… | 见日志 | 脚本、对象、房间等 |
| 合计 | 26 个 chunk 全部处理 | 无「读失败/截断」记录 |

结论：汉化补丁的 `game.win` 结构完整、可被运行时完整解析（26/26 chunk），资源规模与文件大小一致。

## 2. 资源生效情况

| 项 | 状态 | 证据 |
|---|---|---|
| 字体 & 文字渲染 | 已验证 | `FONT` chunk 载入；标题/菜单文字在 iOS 上清晰渲染（`evidence_title.png`） |
| 立绘/角色画（线稿页） | 已验证 | 游戏内 SAVE/LOAD 界面显示 Jill 等角色线稿（`evidence_ingame_saveload.png`） |
| 音乐/音效通道 | 部分验证 | `AUDO` 494.8 MB 全量载入；`nn::audio::OpenAudioOut` 两路 DeviceOut/默认，2 声道 48 kHz「真出声」；无头模拟器无法听觉复核 |
| 汉化文本 | **待验证（有疑点）** | 载入的是汉化补丁 `game.win`，但标题/菜单仍显示日文（ザ・バーテンダー／最初から／ロード／設定）→ 需进游戏「设置」确认语言或在首段对白处复核；见第 4 节 |

## 3. 存读档与界面（部分验证）

| 项 | 状态 | 证据 |
|---|---|---|
| 存档目录挂载 | 已验证 | `save:` 挂到 `Documents/save`（日志「存档提交」路径） |
| 事务式提交 | 已验证 | `存档提交 #1/#2`：`save.work` 克隆后原子换入 `save`，耗时 1.8–4.5 ms |
| 存档界面可达 | 已验证 | 游戏内 SAVE/LOAD 界面（`evidence_ingame_saveload.png`），可用虚拟键/鼠标操作 |
| 完整「存→退→读」回路 | 待验证 | 尚未在游戏内创建进度并读回 |

## 4. 关键功能清单（逐项）

| 功能 | 状态 | 说明 |
|---|---|---|
| 启动到游戏主循环 | 已验证 | `Run_Start` → `Entering main loop.`（`boot_sim.txt`） |
| 标题画面 / 菜单 | 已验证 | `evidence_title.png`；菜单项可被鼠标/虚拟键操作 |
| 点按推进对白 | **已验证（2026-10-17 23:16）** | 重复点按脚本一次跑通：进入新游戏开场旁白并推进到下一段对话（`out/evidence_opening_dialogue.png`、`evidence_opening_dialogue2.png`）；此前卡点是启动时间波动 + 「Aを押してスタート」只认 A，现由点按后内部补 A 解决 |
| 调酒交互 | 待验证 | 需先进入营业流程 |
| 章节推进 | 待验证 | 同上 |
| 设置页 | 待验证 | — |
| 汉化语言生效 | **已验证（中文默认生效）** | 见 [LANGUAGE.zh-CN.md](LANGUAGE.zh-CN.md)：补丁把中文放在「英文」语言槽，宿主按 `en-US` 回答系统语言即整片中文；前端已默认 `DM_LANG=en-US`，证据 `out/cn_p1_rot.png`、`out/evidence_zh_dialogue.png` |

## 5. 输入链路证据（与内容核对相关）

- 触摸：`DM_TOUCH_LOG=1` 时游戏经 `nn::hid::GetTouchScreenStates` 读到面板坐标（例：`(432,547)`、`(640,360)`，属性 1/0/2 = Start/Held/End）。
- 鼠标面：触屏触点被映射为 `nn::hid::GetMouseStates`（位置 + 左键），标题菜单点击生效（点击后出现「Aを押してスタート」）。
- 手柄：虚拟键经 `nn::hid::GetNpadState` 送达；`DM_HID_RECEIPT_LOG` 回执 `buttons:1` 四次，游戏内菜单由 A 键驱动进入 SAVE/LOAD。

## 6. 下一步（按优先级）

1. 在 iOS 上把「新游戏 → 首段对白 → 推进」跑通，顺便确认汉化语言是否随补丁生效（设置/语言项）。
2. 创建进度 → 退出 → 重进读档，补完整存读回路。
3. 调酒与章节推进按桌面基线（`boot52`）逐项对照。
4. 真机（自签 ipa）重复第 1–3 项。

---

# Content verification · iOS (in progress)

Evidence-only record for the P1 content-integrity todo. `game.win` (CN patch, 520,720,771 bytes) loads with all 26 chunks
(SPRT 8.4 MB, FONT 868 KB, TXTR 13.6 MB, AUDO 494.8 MB, CODE 1.66 MB, …), text and character line-art render on the iOS
simulator, audio opens two 48 kHz/2ch outputs, and save transactions commit atomically. Open items: the title/menu text
still shows Japanese despite loading the CN-patch `game.win` (language setting needs checking in-game), dialogue
advancement and the mixing interaction have not been walked through on iOS yet, and the full save/quit/load loop and the
settings page remain unverified. Raw log: `ios_boot_current.txt`; screenshots under `iosapp/out/`.
