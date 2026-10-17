# 输入消费诊断（VA-11 iOS）

## 2026-10-18 00:2x —— 合成 A 是否到达游戏？

加了两个诊断开关（`DM_HID_DIAG=1`）：

1. **未连接样式被请求**日志（`[hid-diag] 未连接样式被请求 id=… style=…`）；
2. **服务出去的 buttons** 日志（`[hid-diag] 服务 id=… style=… buttons=…`）。

在独立设备上跑（标题菜单 + 脚本按 A），结果：

```
[dm] [hid-diag] 服务 id=0 style=1 buttons=0x1 (km=0)     ← 连续 3 条（每秒一条）
触屏读次数: 0
```

### 结论
- 游戏**确实在轮询** `id=0 / style=1(NpadFullKey)`，宿主也**确实把 A（0x1）交给了它**；
- 但标题菜单没有任何反应 → 问题不在「A 没送到」，而在 **runner/GML 怎么解读这一位**（映射表 / 或菜单实际只吃鼠标点击、不吃手柄 A）；
- `触屏读 = 0` → 这份 runner 在标题菜单阶段**不读触摸屏**（只读鼠标/手柄），这也解释了「触屏点击在菜单没反应」的一半原因。

## 下一步
1. 给 `GetMouseStates` 加同样的「服务出去」日志（位置、button），在点击时抓一次，确认鼠标按钮是否被送到、菜单是否读鼠标；
2. 若菜单只认鼠标：核对 `MouseState` 布局（0x20/0x28、button 偏移）与点击时 button 位；
3. 若菜单只认手柄但位映射不同：试 `DM_BTN_B/X/Y/PLUS`（`DM_TEST_STEP` 的 `key:` 步骤）逐个判定哪个位能确认菜单。

## 追加：声明面也查了（2026-10-18 01:3x）

```
[hid-diag] 游戏声明支持手柄号：32,0,1,2,3,4,5,6,
[hid-diag] 游戏声明支持样式=0x1f        ← FullKey|Handheld|JoyDual|JoyLeft|JoyRight 全要
[hid-diag] 鼠标服务 x=640 y=360 button=0 have=1   ← 鼠标确实被轮询（位置对）
[hid-diag] 服务 id=0 style=1 buttons=0x1 / 0x2 / 0x4   ← A/B/X 都被服务出去
```

- 手柄状态布局核对过：`NpadState{int64 sampling; uint64 buttons; int32 lx,ly,rx,ry; uint32 attributes}` 与 Horizon 一致；`DM_BTN_A=1<<0` 与 `NpadButton_A` 一致。
- 结论：**A/B/X 与鼠标位置都到达了 runner，但标题菜单仍无反应**，问题不在传输与布局。

## 剩余假设（按优先级）
1. 该 runner 的 GML 手柄映射表把 face1/face2 对到不同 NpadButton（需试更多位或看 runner 内部映射）；
2. 菜单实际用 **触摸屏**，但实测 `GetTouchScreenStates` 从未被调用（0 次）→ 若如此，这条要单独查为什么 runner 不读触摸；
3. 这个标题菜单是 attract 演示态，交互菜单要在另一状态才接受输入；
4. 我们的 `dm_ui_auto_*` / 独占按键裁决（d2r 时代逻辑）在某些帧把 A 吃掉（服务日志只证明最终结构里有 A，仍需确认 runner 读取时机）。

## 追加：runner 在轮询**键盘**（2026-10-18 01:5x）

```
[hid-diag] 游戏开始轮询键盘状态（GetKeyboardState）
[hid-diag] 键盘轮询次数=600 / 1200 / 1800   ← 每秒 600+ 次，稳定持续
触屏读 = 0
鼠标服务 34 条、手柄服务 8 条
```

**这是本轮最重要的发现**：VA-11 的 GameMaker runner 在菜单/对话阶段**主要用键盘轮询**驱动输入，
而宿主此前 `GetKeyboardState` 一直返回「全 0 空态」——这解释了为什么手柄 A / 鼠标点击都进不去。

### 已实现（代码在 `hle_hid.c`）
- `dm_kbd_press(code, ms)` 键盘注入原语（256 位键位图 + 到期时间）；
- `GetKeyboardState` 现在真正填 `KeyboardState`：`u64 sampling; u64 modifiers; u8 keys[32]（HID 键码位图）; u32 attributes`，总 0x40；
- 产品路径：`tap_a_pulse()` 在点按时同时注入 **Enter(HID 0x28)** 与 **Space(HID 0x2C)**（各 220 ms），
  保留手柄 A 连拍与鼠标点击。

### 仍未验证
- 标题菜单在注入 Enter/Space 后仍未见跳转（截图 `iosapp/out/ks2_rot.png`）；
- 需要确认 `KeyboardState` 的**真实布局/键码**（我们按 HID usage 假设），以及 GM runner 的 `vk_*` 映射；
- 期间还修了一个潜伏编译问题：`loader.c` 的 `image_mh()` 缺前向声明（全量重编译才会暴露），已补。

### 下一步
1. 用 `DM_HID_DIAG` 抓一次「键盘注入时游戏读到什么」（把注入的位图打印出来）确认注入生效；
2. 逐键扫描（Enter/Space/Z/X/方向键）看菜单是否响应，找出 GM runner 的确认键映射；
3. 若键盘布局不对，按 libnx `HidKeyboardState` 实际字段修正（keys 位置/大小、attributes 偏移）。

## 追加：键盘多键/多偏移注入仍未让菜单跳转（2026-10-18 02:0x）

用 `DM_TEST_KBD="150:260:0x28,0x2c,0x1d,0x2b"`（Enter/Space/Z/Tab，持续 110 秒）+ 多候选偏移写入位图，
标题菜单依旧停在 `新游戏/读取/设置`（截图 `iosapp/out/kw2_rot.png`）。

→ 说明「键盘就是菜单确认通道」这个假设**未获支持**（至少按我们的键码/布局假设不成立）。
下一个高价值验证：直接看 GML 侧读数——在 `hle_hid.c` 里对 **GetMouseStates / GetNpadState / GetKeyboardState**
三者的调用频率与「服务值」做一秒一条的对照日志，确认在点击/按键瞬间游戏实际读到了什么（而不是我们以为的什么）。

## 追加：runner 的输入栈入口全部被调用（2026-10-18 02:0x，commit a4953d5）

```
[hid-call] InitializeKeyboard 被调用
[hid-call] InitializeMouse 被调用
[hid-call] InitializeNpad 被调用
[hid-call] SetSupportedNpadIdType 被调用
[hid-call] SetNpadJoyHoldType 被调用
[hid-call] SetSupportedNpadStyleSet 被调用
[hid-call] GetNpadJoyHoldType 被调用
[hid-call] GetNpadStyleSet 被调用
```

**结论**：GameMaker runner 的三路输入（手柄/鼠标/键盘）都走完整初始化，配置接口也都调了；
配合此前「三路状态都确认送达」→ 输入链路**本身没有问题**。

但：
- 菜单态下**游戏不绘制鼠标光标**（多帧截图都没有），与早前 `evidence_title.png` 里出现手形光标的状态不同；
- 悬停 + 移动路径 + 点击「新游戏」位置均无反应（`out/hp2_rot.png`）。

→ 高置信判断：当前画面是 **attract 演示态**（菜单只是演示的一部分），交互菜单在另一个状态；
下一步应先用**多帧序列**确认状态机（是否循环回「按 A 键开始游戏」），再找一个真正可交互的状态。

## 追加：两种排除（2026-10-18 02:2x）

1. **换运行模式**：`DM_OPMODE=0`（掌机）时 runner 改为轮询 `id=32 style=2`（NpadHandheld），
   宿主也照常服务（日志 4 条），但标题菜单仍不响应（`out/hh2_rot.png`）。
2. **Y 轴翻转**：按镜像 Y（0.19）依次点「新游戏/读取/设置」三个位置，仍无反应（`out/yf2_rot.png`）。

→ 坐标口径与运行模式都不是原因；结合「菜单态无鼠标光标」，继续指向 attract 演示态/状态机。

## 另一个可查线索
game.win 的 GML 里有一整组 Switch 专用封装：
`switch_gamepad_button_check/pressed/released`、`switch_event_mouse`、`switch_controller_support_show`、
`switch_controller_set_supported_styles`、`switch_get_operation_mode`、`switch_lstick_active` 等。
说明游戏自己包了一层输入层；下一步可以直接看这组脚本的字节码（需要 GML 反汇编），
或观察它们在运行期是否被调用（host 侧看不出，需在 guest 里打桩/断点）。

## 追加：掌机模式下游戏**确实轮询触屏**，触点是合法按下/按住/抬起（2026-10-18 02:5x）

`DM_OPMODE=0` + `DM_TOUCH_LOG=1` 实测：

```
触屏读 采样 4313 触点 1 | #0 (640,360) 属性 1   ← 按下
触屏读 采样 4314..4316 | #0 (640,360) 属性 0   ← 按住
触屏读 采样 4317 触点 1 | #0 (640,360) 属性 2   ← 抬起
触屏读 采样 4464 触点 1 | #0 (486,583) 属性 1   ← 点「新游戏」位置(0.38,0.81) 的按下
```

- **掌机模式**下游戏读触屏（console 模式 0 次）；
- 触点坐标正确（(486,583) 就是我们的归一化坐标换算结果）；
- 属性序列 1→0…→2 正是「按下→按住→抬起」。

但菜单仍不跳转。结合前面的 gamepad/键盘实验，下一步要查的是：
**游戏在标题态是否把触摸只用于 `switch_save_clickable` 的存档点击，而菜单项只吃手柄确认键**；
以及 `switch_gamepad_button_check` 这层脚本最终调用的是 GM 内置 `gamepad_button_check` 还是扩展函数。

## 用户更正 + 触屏链路复核（2026-10-18 02:4x）

**用户更正（真机 NS 验证）**：掌机模式下**仅用触屏**就能进菜单并开始游戏。
→ 所以触屏路径必须打通；之前「菜单只吃手柄」的假设作废。

本轮实测（`DM_OPMODE=0` 掌机）：
1. 提示文本变成 **「轻触或按 A 键开始游戏」**（截图 `out/tn2_rot.png`）——游戏自己声明触屏可用；
2. `GetTouchScreenStates` 被高频轮询（采样号到 6 万+）；
3. 触点推送链路正确：`[touch-trace] 推 1 点 (0.500,0.500)` → `推 0 点（抬起全部）`；
   读到的序列是 `属性 1（Start）→ 0…（按住）→ 2（End）`，坐标 `(640,360)` 与注入一致；
4. `GetTouchScreenStates` 现在按真机语义**填满请求份数并返回 n**（原来只填 1 份返回 1）。

但「轻触」仍未让提示消失。剩余怀疑：
- TouchState 的 `finger_id`（真机可能从 1 起）或 `attributes` 语义与真机不同；
- 游戏判定「轻触」可能需要更短的按住（当前 120 ms）或需要一次完整 down→up 落在同一帧间隔内；
- 该提示可能只吃 A（游戏数据里也有「轻触」文案，但逻辑另说）。

下一步：把 finger_id 改成 1、把点按改短（60–80 ms），并对照真机 attributes 语义再试。
