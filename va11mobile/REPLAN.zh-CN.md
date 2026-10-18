# 自主周期复盘（replan 记录）

- 触发：`periodic_review_due` —— 自上次自主复盘以来已结算 6 个工作 Turn（run_history 阈值 6）
- obligation：`replan-7f38047ea267d3b4`（owner: va11-ios-porter / peer_v1）
- 时间：2026-10-17（Asia/Shanghai）
- 范围：`va-11-ios-goal` 的 peer lane；不改用户授权范围、不缩减目标

## 1) 现状核对（只用已有证据）

| 区域 | 状态 | 依据 |
|---|---|---|
| 无签名 ipa 流水线 | 完成 | `iosapp/out/Va11IOS-unsigned.ipa`（16.9 MB，arm64，`verify.txt` 0 红） |
| iOS 核心移植（宿主/HLE/出图/触摸/音频/FS/游戏数据） | 完成并结算 | 主循环 `Entering main loop.`；`evidence_title.png`；`evidence_ingame_saveload.png` |
| 输入链路 | 已通 | 触屏→`dm_touch_set`；触点→鼠标面；虚拟键 A/B/＋/十字键经 `nn::hid` 送达（HID 回执） |
| 内容数据完整性 | 已验证 | `verify/VERIFY.zh-CN.md`：26/26 chunk，SPRT/FONT/TXTR/AUDO/CODE 字节数与文件一致 |
| 交付文档 | 完成 | `va11mobile/README.md` + `iosapp/README.md` |
| 对白推进 / 调酒 / 章节 / 设置页 | **未验证（卡点）** | 标题与 SAVE/LOAD 可达，但对白推进在 iOS 上未跑通 |
| 汉化语言 | **存疑** | 载入汉化补丁 `game.win`，标题/菜单仍显示日文 |

## 2) 复盘决策

- **keep**：P0「iOS 壳 App」与 P1「内容完整性核对」两条主线保留，不缩减验收。
- **split**：把壳 App 剩余路径拆成可独立验证的切片（对白推进、汉化语言、调酒/设置），避免一个 todo 长期悬空。
- **add**：新增 4 个可运行 successor（见下），其中第一个是「输入时序 vs 对白 HLE」的判别性探针。
- **retire**：无（P2 文档已于上一轮完成）。
- **ask_decision**：不触发（未改变 benchmark family、公开声明、资源预算或受保护范围）。

新增 todo（agent lane）：

| 优先级 | todo | 目的 |
|---|---|---|
| P0 | `todo_2441b81a72ce40b6996cf330` 新游戏→首段对白推进（判别探针） | 分清「A 提示不推进」是输入时序还是对白 HLE |
| P0 | `todo_a43a929b2927f43843255d6f` 汉化语言确认 | 设置/语言项 + 首段对白文本证据 |
| P1 | `todo_c17472a67f69bb3fffe3c7ed` 调酒交互与设置页走查 | 逐项记录证据与待验证项 |
| P1 | `todo_1e76884ca8ceb98dcb0ed82d` 真机自签安装 + 首启验证 | 真机闭环（需设备/签名环境） |

## 3) 选定的下一片（selected next slice）

`todo_2441b81a72ce40b6996cf330` —— 用判别性探针回答：「`Aを押してスタート` 不推进是因为输入没被消费，还是对白/消息 HLE 阻塞」。

- 探针设计：同一次启动里（模拟器）用 `DM_TEST_PAD` 在提示出现后分别给 **短脉冲（120 ms）** 与 **长按（≥1.2 s）** 的 A，
  同时开 `DM_HID_RECEIPT_LOG` 记录游戏侧收到的 `buttons`；`DM_TOUCH_LOG` 记录触点读取；截图对比状态是否变化。
- 判别标准：
  - 回执里出现 `buttons:1` 且长按后画面仍停在提示 → 不是输入时序，按「对白/消息 HLE 或脚本阻塞」处理（与 peer lane
    的 `dmhost_m3 dialog HLE 专项` 对齐，先出最小复现记录，不抢改共享宿主文件）；
  - 回执里长按期间出现连续 `buttons:1` 且画面推进 → 输入时序问题，把虚拟键/触摸推进改成「按到游戏消费为止」（
    已有 `dm_input_samples` 机制可接）。
- 验证命令（模拟器）：
  ```sh
  cd va11mobile/iosapp
  DEV=<sim-udid>
  SIMCTL_CHILD_DM_HID_RECEIPT_LOG=/tmp/hid.jsonl \
  SIMCTL_CHILD_DM_TEST_PAD="40:A;55:A;70:A" \
  xcrun simctl launch --terminate-running-process "$DEV" local.va11.mobile
  # 60–90 s 后截图 + 拉回 Documents/boot.txt 与 /tmp/hid.jsonl
  ```
- 停止条件：若判定为对白/消息 HLE，且修复需要改动 peer lane 正在改的共享宿主文件 → 只记录最小复现与证据，停在 blocker，
  不并发改共享文件、不重复花费。

## 4) 下次复盘要检查

- 上述探针是否真的改变了后续工作与权威结果（不是只写了决策）；
- 汉化语言疑点是否被证据回答；
- P1 内容核对表里「待验证」项是否减少。

---

# 第二轮自主复盘（replan-ed4eeb314601ebc8）

- 触发：`periodic_review_due`（自上次复盘又结算 6 个工作 Turn）
- 观察：这 6 轮都围绕「汉化语言」，且连续出现无效假设：
  1. 系统语言（`nn::oe::GetDesiredLanguage` 返回 zh-Hans）已确认被游戏查询，但文本仍日文；
  2. `Settings/Settings.json` 是 d2r 遗留，改它无效；
  3. `Waifu Preferences.txt` 8 个值全改 2 也无效（文件未回写）。
- 证据化结论：数据里同一句 UI 有 `Aを押してスタート`/`Press A`、`新游戏`/`New Game`/`最初から`，
  语言是运行时选择；剩下两条可行路径：(a) 游戏内设置页的「简体中文」按钮；(b) 服务层语言查询
  `nn::settings::GetLanguageCode`（sdk 服务路径，可能才是 runner 实际用的）。

## 决策
- **keep**：P0 壳 App、P1 内容核对两条主线。
- **split**：语言 todo 拆成三步（UI 标定 / 新假设 HLE settings 语言 / 设置页切中文并 diff 配置）。
- **add**：三个可运行 successor：
  `todo_81249f6e8807525f6d49d7e9`（UI 单步标定）、`todo_3ec122904e331bed59a7e807`（HLE settings 语言新假设）、
  `todo_bd50bf2b03e596d6e63c5166`（设置页切中文 + diff 持久化键）。
- **retire**：无；**ask_decision**：不触发（未改公开声明/预算/受保护范围）。

## 选定下一片
`todo_81249f6e8807525f6d49d7e9`：用「单步 + 截图」标定标题菜单与「設定」的归一化坐标，先能在模拟器里稳定进设置页；
之后 `todo_3ec122904e331bed59a7e807` 做 HLE 服务层语言假设的对照实验。

## 验证命令与停止条件
- 验证：`simctl launch`（无测试脚本）→ 等主循环 → 手工/点按进设置页 → 截图记录坐标与页面。
- 停止条件：若设置页需要触屏坐标以外的资源（如键盘），记录阻塞并转 HLE 新假设。

---

# 第三轮自主复盘（replan-60136b999a391fce）

- 触发：`periodic_review_due`（又 6 个结算 Turn）。
- 观察（近 6 轮）：主题集中在「用户手动操作模拟器」与「点按补 A」，出现了这些结果：
  1. 语言问题已彻底解决（补丁中文在英文槽，默认 `DM_LANG=en-US` → 开箱中文，有干净安装端到端证据）；
  2. 但用户侧点击仍无反应，且 boot 日志显示 **touch reads = 0**（点击没进 App）→ 窗口焦点/窗口选择问题；
  3. 我的重复测试脚本会反复拉起 App，干扰用户操作（已停旧测试设备）。
- 结论：验收输入不能依赖「用户点窗口」或「墙钟重复点按」；需要一条**不依赖窗口焦点**的单步注入路径。

## 决策
- **keep**：P0 壳 App、P1 内容核对。
- **split/retire**：语言类收尾 todo 已无必要（语言已解决），暂留 open 但不再投入（defer 需 lease 证明，未强行改状态）。
- **add**（新路径/新可运行 successor）：
  - `todo_82fafed088984b82af2c932f`（P0）hover→click→A 单步注入钩子（不依赖窗口焦点），供菜单/设置/调酒验收；
  - `todo_681d276649800874b476bae8`（P1）长跑脚本推进到酒吧调酒环节并取证（中文）。

## 选定下一片
`todo_82fafed088984b82af2c932f`：实现单步注入钩子，让「进菜单→设置→退出一句话」可以脚本化、可重复，
再用它把设置页与调酒环节的证据补齐。

## 验证命令与停止条件
- 验证：`DM_TEST_STEP="hover:0.338,0.76;wait:200;click:0.338,0.76"` 形式的钩子，一次启动走一步、截图核对。
- 停止条件：若注入仍受窗口焦点影响（即 dm_touch_set 路径本身依赖前台），改从 HID/EMU 输入面直接注入并记录架构变化。

---

# 第四轮自主复盘（replan-0ef5c7f009a34f6b）

- 触发：`periodic_review_due`（又 6 个结算 Turn）。
- 观察：近 6 轮全部投入「输入为何进不去菜单」，已有结论：
  1. 手柄 A/B/X、键盘 Enter/Space/Z/Tab、鼠标点击**都确认送达 runner**（`DM_HID_DIAG` 日志有服务值）；
  2. 键盘被高频轮询（600+/s），但注入键盘无效；
  3. 本轮从 game.win 字符串表确认 GML **同时使用** `gamepad_button_check`、`switch_gamepad_button_*`、
     `keyboard_check*`、`device_mouse_*`、`mouse_check_button*` —— 三路都是候选通道，单路试错效率低。
- 结论：不再「一条通道一条通道试」，改成**三路对照日志**（同一时间窗内记录读取次数 + 服务值），
  让数据直接指出菜单实际读哪一路；同时并行推进不依赖输入的验收清单整理。

## 决策
- **keep**：P0 壳 App（输入/触屏）、P1 内容核对。
- **add**：
  - `todo_def78619f3ca23242eabe6b4`（P0）三路对照日志定位菜单确认通道；
  - `todo_0811b2e97db5b3184e95d602`（P1）验收清单整理（不依赖输入，可并行推进）。
- **retire/降权**：语言遗留两条（`todo_81249f6e`、`todo_bd50bf2b`）已无必要，但 defer 需 lease 证明，
  本轮不强行改状态，不再投入。

## 选定下一片
`todo_def78619f3ca23242eabe6b4`：三路对照日志。

## 验证命令与停止条件
- 验证：`DM_HID_DIAG=1` + 一次启动，在点击/按键瞬间抓三路「读取次数 + 服务值」并截图。
- 停止条件：若三路在菜单态都被读取且服务值正确仍无反应 → 转「菜单状态机（attract）不接受输入」假设，
  用画面序列（多帧截图）确认，而不是继续加输入通道。
