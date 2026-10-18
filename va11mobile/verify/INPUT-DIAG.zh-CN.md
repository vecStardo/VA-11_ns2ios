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

## 单步注入钩子验收 + 按下沿诊断（2026-10-18 10:4x）

`DM_TEST_STEP` 钩子（hover→click→A 单步脚本，不依赖窗口焦点）本轮做了两处修正并实测：

1. **点击带真实落点**：原来 `tap_a_pulse()` 里的帧同步点击固定报 `(0.5,0.5)`，菜单项不在屏幕中心；
   现在拆成 `tap_a_pulse_at(nx,ny)`，产品触屏路径用真实触点坐标，脚本 `click:x,y` 也带各自坐标。
2. **按下沿诊断不再被节流吞掉**：鼠标服务日志原来每秒最多一条，而合成点击的按下沿只维持 2–3 拍（~33 ms），
   会被整段漏掉。现在 `button 0→1` 的跳变**无条件记一行**。

实测日志（模拟器 VA11-User，`DM_TEST_STEP='at:7000;hover:0.5,0.5;wait:300;click:0.5,0.5;…'`）：

```
[dm] [test] 单步脚本 at:7000;hover:0.5,0.5;wait:300;click:0.5,0.5;wait:1500;key:A;wait:1000;click:0.5,0.62
[dm] [test] 步:悬停 (0.500,0.500)
[dm] [hid-diag] 鼠标服务 x=640 y=360 button=0 have=1
[dm] [test] 步:click (0.500,0.500)
[dm] [hid-diag] 鼠标按下沿 服务 x=640 y=360 button=1 have=1     ← 帧同步点击确实被服务出去
[dm] [hid-diag] 服务 id=32 style=2 buttons=0x1 (km=0)            ← 手柄 A（掌机 id=32/style=2）
[dm] [test] 步:click (0.500,0.620)
[dm] [hid-diag] 鼠标按下沿 服务 x=640 y=446 button=1 have=1
```

分辨率/坐标换算正确（0.5,0.62 → 640,446 面板坐标），单步钩子可用 → `todo_82fafed088984b82af2c932f` 收口。

### 仍未解决：标题「轻触或按 A 键开始游戏」不消失

同一次运行截图（`out/prog_26.png`）停在标题画面，提示仍是「轻触或按 A 键开始游戏」；
A 按住数秒（`buttons=0x1` 连续多秒）与带落点点击都没有推进。已排除：
- 传输层：鼠标按下沿、手柄 A、键盘轮询都被服务出去（有日志）；
- 单帧边沿被吃：A/click 都是多拍连续；
- 复数接口缺失：`GetNpadStates`（复数）从未被调用（未实现导入只有 1 条且是 `nnosGetDefaultUserExceptionStackForApplication`），
  说明 runner 只走单数 `GetNpadState`。

### 三个子智能体的公开资料调研（本轮）

1. **同路线衍生项目 `seedds/nxnative`**（复用 d2r-mobile 的 NSO rewriter + Horizon HLE + NVN→Metal，已跑通 6 款 Switch 游戏）：
   hid 层补全**全部 Npad 样式** + `GetNpadStates`（复数，伪历史：当前状态重复 n 份、sampling 连续）+ **按下沿锁存**；
   触屏只做虚拟手柄映射，不提供 touchscreen/mouse/keyboard。
2. **d2r-mobile 自己踩过同构的坑**：`hle_touch.c` 手指状态机（EMPTY/DOWN/LIFTED，先报 Start、抬起补报 End）+
   `hle_hid.c` press-edge latch（注释写明「真机 0.09 ms 的按键整个丢失→点了没反应」）——我们已照搬触屏状态机，按键锁存尚未照搬。
3. **GameMaker 侧资料**：Switch runner 默认只映射**掌机自带手柄**，分离 Joy-Con 要游戏侧自建对象轮询（GBAtemp 移植教程）；
   触屏走 `device_mouse_check_button*`；`keyboard_check_pressed` 只在跳变帧为真；PC 版有作者实测「合成鼠标点击无效」。
4. **汉化补丁**：Switch 版补丁署名 dkdjrj、标称只支持 1.0.1，公开渠道没有任何文件清单/game.win 分析；
   GameMaker 主机版 `game.win` 是 UMT 从 `data.win` 转出的自包含容器 → 补丁 game.win 可能是二手重建物（**假设，未验证**）。

### 下一步（按优先级）

1. **照搬 nxnative 的按键按下沿锁存**（前端按下 → 锁存到游戏下一次读，读完清）：与现有帧同步点击队列叠加，
   解决「按下沿刚好落在两次采样之间」这一类。
2. **补 `GetNpadStates`（复数）+ 伪历史**：即使本轮未见调用，显式实现后可排除「runner 在别的路径用它」的可能，
   且 n=2 时第 [1] 项可作为上一拍（GM 边沿检测习惯）。
3. **换未汉化原版 game.win 跑同一 HLE**：能进菜单即锁定汉化补丁重建的问题；仍不能进则问题在 HLE 输入层。
4. **焦点/暂停门控排查**：确认 `nn::oe::GetOperationMode`=Handheld、`GetFocusState`=InFocus、
   `nn::oe::GetResumeFlag` 等是否被调用/取值是否正确（GM 用 `window_has_focus` 吞输入）。

## 按 HID 规范修正两个结构体错误（2026-10-18 11:0x）

对照 switchbrew / libnx 的 HID 结构定义，`hle_hid.c` 里两处**写错**已修正：

1. **KeyboardState 长度是 0x30，不是 0x40**（`u64 sampling; u64 modifiers; u64 keys[4]`，**没有 attributes 字段**）。
   原实现 `memset(p, 0, 0x40)` 并写 attributes，会写穿调用方缓冲区 → 已改为 0x30。
2. **MouseState.attribute 位定义**：bit0 = Transferable、bit1 = IsConnected。
   原实现只写 `1`（= 可传输但**未连接**），引擎普遍先判 IsConnected 再取按键 → 触摸合成的鼠标会被整只忽略。
   已改为 `have ? 0x3 : 0`（Transferable | IsConnected）。

验证（模拟器 VA11-User，三次 `click:0.5,0.5`）：按下沿日志正常
（`鼠标按下沿 服务 x=640 y=360 button=1 have=1`），键盘轮询与手柄 A 不受影响；
标题画面仍未推进（下一步按调研建议补「按下沿锁存」与 focus/许可门控排查）。

## 读侧统计 + 复数 GetNpadStates（2026-10-18 11:2x）

之前只有「服务出去多少」的日志，没有「游戏每秒在读哪些输入面」的统计。本轮加了 `[hid-read]` 每秒汇总，
并补了复数接口 `GetNpadStates`（通用 / FullKey / Handheld，伪历史：n 份重复当前状态、sampling 连续递减）。

标题画面实测（模拟器 VA11-User，`DM_OPMODE=0` 掌机，DM_TEST_STEP 在第 6 s 按 A、第 9 s 点击）：

```
[dm] [hid-read] 每秒读取 npad=26 touch=26 mouse=417 kbd=26
[dm] [hid-read] 每秒读取 npad=25 touch=25 mouse=400 kbd=25
[dm] [hid-read] 每秒读取 npad=25 touch=25 mouse=401 kbd=25      ← 标题态稳定：每帧一次 pad/touch/kbd，鼠标每帧约 16 次
[dm] 强制接管条目无任何引用：_ZN2nn3hid14GetNpadStatesEPNS0_17NpadHandheldStateEiPKj   ← 复数接口未被导入
```

**结论**：
1. 标题态**连续读触屏**（25 次/秒，与 pad/keyboard 同拍），不是「不读触摸」；
2. 帧率约 25 fps（每帧一次输入采样）；我们 120 ms 的 A 连拍 ≈ 3 帧，不是「落在两帧之间」；
3. `GetNpadStates`（复数）**不在导入表里**（`强制接管条目无任何引用`）→ 之前「复数接口缺失导致边沿恒 0」的假设**排除**；
4. 四路输入都在被读、且值都被服务出去，但标题仍不推进 → 怀疑点收敛到
   「runner 把底层状态翻成 GML 输入的映射」或「游戏实际停在前一个逻辑状态（存档/账号/加载）」。

**排除项汇总**（本轮后）：传输层（有服务日志）、采样频率（25 fps 覆盖）、复数接口（无导入）、
单帧按下沿（多拍连发）、键盘 buffer 越界与鼠标 IsConnected（已修）、focus 默认值（=1 InFocus）。

**剩余待验**：原版（未汉化）game.win 对照需要 prod.keys，本机没有（`~/.switch` 与工程内均无）
→ 已记为需要用户提供原版 romfs/game.win 或 keys 的用户动作，不再空转。

## 全按键 + 多点位点击爆测（2026-10-18 11:4x）

一次运行里按顺序发：A、PLUS、B、X、Y，再在 (0.5,0.5)/(0.86,0.5)/(0.5,0.9)/(0.14,0.5)/(0.5,0.1) 各点一次
（`DM_TEST_STEP`，掌机模式 `DM_OPMODE=0`）。服务日志逐一确认到位：

```
[hid-diag] 服务 id=32 style=2 buttons=0x1    ← A
[hid-diag] 服务 id=32 style=2 buttons=0x400  ← PLUS
[hid-diag] 服务 id=32 style=2 buttons=0x2 / 0x4 / 0x8   ← B / X / Y
[hid-diag] 服务 id=32 style=2 buttons=0x1    ← 每次点按补的 A
```

结果：标题「轻触或按 A 键开始游戏」**依旧不消失**（截图 `out/burst.png`）。

- 说明不是「按键位没发对」：面键全发、PLUS 也发了、5 个位置都点了；
- 也不是「只有某个位置可点」：中心与四边都试过；
- 结合读侧统计（touch/pad 每帧都在读），症状收敛为：**游戏自己没有把这帧输入当成「确认」**，
  或者它停在前一个逻辑状态（存档/账号/加载）而标题只是渲染残留。

另外确认：截图左下角的「+」是**我们 iOS 壳自己画的触屏十字键浮层**（`main.m` 的 D-pad 覆盖层，方向键映射到 nn::hid 的 Left/Up/Right/Down），
不是游戏画的光标，之前的截图差异（有/无 +）只是浮层显示条件不同。

## 无输入长跑：游戏自己在走 attract（2026-10-18 10:3x）

关键新发现：**完全不发输入**跑 105 秒，画面已经进入开场旁白（中文「我们还要在这里呆多久？」，
截图 `out/idle_105.png`），说明：
1. 游戏没有卡死——标题→开场是**自动推进的 attract/演示循环**（4 次截图两两不同，画面持续在演）；
2. 中文旁白在没有任何输入的情况下正常出图 → 语言与字体链路 OK；
3. 之前「标题不响应」的判断需要修正为：**标题是 attract 循环的一部分**，我们在 5–13 s 的输入落在 attract 上，
   而 attract 不一定接受输入；真正需要验证的是「attract 结束后/在对话里」的输入。

随后在 88–98 s 注入 click ×3 + A ×2，110 s 截图回到标题（`out/inp_110.png`）——
说明 attract 会**循环回标题**，不同运行在同一时刻所处循环位置不同，因此“某一时刻的截图对比”不能作为输入是否生效的证据。

### 结论与下一步
- 现阶段的正确验收方式不是「拍某时刻截图」，而是**在对话/菜单里连续按确认并观察文本是否推进**；
- attract 循环的存在也解释了此前「按 A 没反应」的一大半现象：输入大概率没有作用在可交互状态上；
- 仍需原版 game.win 对照来排除「汉化补丁把菜单对象改坏」；若补丁无问题，则下一步在对话状态下做输入验收，
  并考虑给壳加一个「跳过 attract 直接进标题菜单」的注入入口。

## 原版 vs 汉化补丁 A/B 对照（2026-10-18 10:5x）

用户把 `prod.keys` 放进仓库根目录后，成功拿到**未汉化原版 game.win**：
- `nsz -D` 解 NSZ→NSP 可以，但 `nsz -x` 无法从 NSP 递归解出 NCA 内容（需要 title key，
  `--titlekeys` 生成 title.keys 后 nsz 仍报 `MissingTitleKeyError`）；
- 绕开 nsz：早前工具 `tools/va11_extract.py` 已把明文 dump（NCZ 段 cryptoType=1，无需 keys）解成
  `~/va11-work/program.nca`；romfs 的 data 段就是 `FORM + len + GEN8` 的 GameMaker 容器。
  新增 `tools/extract_original_game_win.py` 按该特征扫描落盘：
  `game.win: 520720771 字节 @ 0x47e200, sha256 e860d56e709c1883…`（补丁版是 `ff5220e0…`，同尺寸）。

模拟器同一 HLE、同一点按脚本（每 4 s 一次持续点按）分别跑两个 game.win：
- **原版**：标题显示英文 `The Ballad of a Gay Ghost 1.2.3.0` + `Tap or press A to start`，
  attract 播到酒吧场景旁白（`out/orig_90.png`），随后循环回标题（`out/og_140.png`）；
- **汉化补丁版**：同样循环，只是 attract 内容显示中文旁白（`out/idle_105.png`）。

**结论（重要）**：GameMaker runner 是官方 Switch runner，两个 game.win 都能被加载、出图、跑 attract；
点按在**两个版本上都不推进标题** → **输入问题不是汉化补丁造成的**，而是我们的 HLE/host 输入路径。
同时确认：NSZ 本体实际是 **1.2.3.0**，而汉化补丁标称只支持 1.0.1 → 补丁与本体版本不匹配是另一个独立问题
（可能造成文本/界面错位，但不是本次输入问题的原因）。

### 复现命令
```
nsz -D -o ~/va11-work/orig "…/[010086500D3C8000][v0].nsz"           # 解成 nsp
python3 tools/va11_extract.py <ncz> ~/va11-work                      # 解出 program.nca（明文段）
python3 tools/extract_original_game_win.py ~/va11-work/program.nca ~/va11-work/orig/game.win
cp ~/va11-work/orig/game.win <App 容器>/Documents/save/game.win      # 模拟器对照用
```

## focus/许可门控排查 + 「点按确实改变了行为」（2026-10-18 10:5x）

给 `hle_oe.c` 加了读侧统计（`[oe-read]`，记录首次读取的值与每 600 次读的次数），实测：

```
[dm] oe::SetFocusHandlingMode 2
[dm] [oe-read] GetOperationMode 首次被读 → 0（0=Handheld）
（没有任何 GetCurrentFocusState 读取记录 → runner 从不查焦点）
```

→ **焦点门控假设排除**：runner 不读 `GetCurrentFocusState`；运行模式报的是掌机 0；它只是把焦点处理模式设成 2（不通知）。

### 新线索：点按确实改变了游戏行为

同一时刻起跑、同一取样时刻对比「完全无输入」与「18 s 单次点按」：

| 采样时刻 | 无输入（A） | 18 s 单次点按（B） |
|---|---|---|
| 20 s | 动态画面 | 与 A 相同 |
| 25 s / 35 s | 两帧不同（attract 在演） | **两帧完全相同（画面静止在标题）** |

三次点按（18/22/26 s）版本同样：32 s 后 40 s 与 50 s 两帧完全一致（`out/C_50.png` 仍是英文标题
`Good Bye Miss Bartender 1.2.3.0 / Tap or press A to start`）。

**解释**：点按**不是完全没到**——它把 attract 演示打断成静止标题；但「从标题开始游戏」这一步没被接受。
这解释了此前所有「看起来没反应」的观察，也把问题缩小到：**attract→标题 的输入路径能走通，
标题→开始 的路径走不通**（可能是不同的输入分支：`keyboard_check(vk_anykey)` 类全局键 vs
标题专用按钮/点击区域）。

### 下一步
1. 对比「attract 中断」与「标题开始」两个分支在 GML 侧用什么函数（下一步需要反汇编/字符串定位）；
2. 试 `DM_TEST_STEP` 在 attract 中断后再等 10 s 才按键（避免两次输入落在同一状态机里）；
3. 若标题开始只用指针**点击特定区域**，需要用归一化坐标扫描标题上的可点区域（而非屏幕中心）。

## 标题可点区域网格扫描（2026-10-18 11:0x）

假设：`Tap or press A to start` 可能只认标题上某个特定可点区域，而中心点不在其中。
做法：先等 20 s（attract），再沿 3 行 × 5 列（x=0.2/0.35/0.5/0.65/0.8，y=0.25/0.5/0.75）
共 15 点逐点点按，每点间隔 2.2 s，行间截图（`out/grid_r1..r3.png`、`out/grid_end.png`）。

结果：15 个点全部点过，画面仍在标题（英文 `Good Bye Miss Bartender 1.2.3.0 / Tap or press A to start`）。

**推论**：标题「开始」不是「屏幕某个坐标的热区」能解决的问题；结合此前「全按键爆测」（A/B/X/Y/PLUS 全发）
也无效，问题更可能在 **runner 把 hid 状态翻译成 GML 输入的映射层**（触摸→device_mouse、手柄位→GML
gamepad 常量），而不是命中区或键位本身。

### 下一步（范围较大，按投入排序）
1. **反汇编官方 runner 的输入翻译层**：NSO 已剥符号，需要在 `main/sub sdk` 里定位读 `GetNpadState` /
   `GetTouchScreenStates` 返回值之后的转换代码（按返回结构偏移特征搜索），确认它期望的 attributes/边沿语义；
2. 或换一个**已知能被该 runner 正常驱动**的 GameMaker Switch 游戏做对照（可验证是通用映射问题还是本作特例）；
3. 真机侧：在真机上跑同一份 HLE 构建并对比（真机触屏可用），确认是否 iOS 前端特有（如视图旋转/坐标轴）。

## runner 的 hid 导入清单（反汇编前的地基，2026-10-18 11:1x）

`~/va11-work/exefs/*.bin` 是解压后的模块载荷（`.nso` 里各段是压缩的，直接 grep 原文件拿不到符号）。
在 `main.bin`（GameMaker 官方 runner）里可以 grep 到它**导入的全部 46 个 nn::hid 符号**，输入相关的正是：

```
_ZN2nn3hid12GetNpadStateEPNS0_16NpadFullKeyStateERKj        ← 5 种样式各一个
_ZN2nn3hid12GetNpadStateEPNS0_16NpadJoyDualStateERKj
_ZN2nn3hid12GetNpadStateEPNS0_16NpadJoyLeftStateERKj
_ZN2nn3hid12GetNpadStateEPNS0_17NpadHandheldStateERKj
_ZN2nn3hid12GetNpadStateEPNS0_17NpadJoyRightStateERKj
_ZN2nn3hid14GetMouseStatesEPNS0_10MouseStateEi
_ZN2nn3hid16GetKeyboardStateEPNS0_13KeyboardStateE
_ZN2nn3hid20GetTouchScreenStatesILm16EEEiPNS0_16TouchScreenStateIXT_EEEi
_ZN2nn3hid15GetNpadStyleSetERKj / _ZN2nn3hid24GetSupportedNpadStyleSetEv
_ZN2nn3hid22SetSupportedNpadIdTypeEPKjm / SetSupportedNpadStyleSet<…>
_ZN2nn3hid29Set/GetNpadHandheldActivationMode…
```

**意义**：
1. runner **同时导入四路输入**（手柄 5 样式 / 鼠标 / 键盘 / 触屏 16 点），说明翻译逻辑全在 runner 内部；
   这与读侧统计（npad=touch=kbd≈25/s、mouse≈400/s）完全一致，HLE 侧确实没有缺接口；
2. 触屏用的是 `GetTouchScreenStates<16>`（带 count 参数、返回已写条数），没有别的触屏入口；
3. 由此确认下一步只能做**翻译层反汇编**：在 `main.bin` 里定位这些导入的 PLT 调用点，
   看它在返回结构里读哪些偏移、如何生成 GML 的 `device_mouse_*` / `gamepad_*` / `keyboard_check` 结果。

### 方法学修正
之前用「两张截图 hash 是否相同」判断画面是否静止并据此推断输入生效，**不可靠**：
标题本身有 glitch 动画，不同运行/不同时刻的 hash 都会不同；hover-only / key-only / click / idle
四种输入在同一采样时刻得到过相同 hash（`1cbeeeb97f45`）也得到过不同 hash。
→ 后续验收改为**内容分类**（例如对截图做一次视觉判定是「标题 / attract 演示 / 对话」）或
直接读游戏内部状态，而不是比 hash。

## 突破：不再伪造鼠标，输入通了（2026-10-18 11:2x）

按「真机 fidelity」改了一个点：**Switch 没有鼠标设备，官方 runner 看到的 `GetMouseStates` 永远是 0 条**，
而我们一直伪造「已连接鼠标」（`MouseState.button/attribute` 非空）。加开关验证：

```
DM_NO_MOUSE=1：GetMouseStates 返回 0 条
[hid-read] 每秒读取 npad=26 touch=26 mouse=0 kbd=26   ← mouse 接口仍被轮询，但拿不到状态
```

结果（同一套点按脚本）：**点按立刻进入游戏 UI** —— 截图 `out/nm_50.png` 是游戏内 **LOAD（读档）界面**：
保存槽 1–6、LOAD 标题、光标手、R/L 提示都在，且 `nav_50.png` 里光标换到了另一个槽位（输入在导航）。

### 结论

之前伪造的「已连接鼠标」让官方 runner 走了鼠标路径并把**触屏合成 `device_mouse` 的路径遮蔽**，
所以标题永远不前进；按真机语义返回「无鼠标」后，触屏点按恢复正常工作。

**产品代码已改**：`hle_hid.c` 的 `GetMouseStates` **默认返回 0 条**（真机语义），
只有 `DM_MOUSE=1` 才恢复旧行为（留作对照/调试）。`GetTouchScreenStates` / 手柄 / 键盘不受影响。

### 待验证（下一轮）
1. 从标题进入「新游戏」，走到开场对白/酒吧场景（点按推进）；
2. 重打无签名 ipa（把该修复带进交付物）并更新 README；
3. 用汉化补丁版 game.win 再跑一遍（中文 UI + 可交互）。

## 修复后的交互验证（2026-10-18 11:1x）

默认（真机语义，`GetMouseStates` 返回 0 条）下，点按已经能进入并操作游戏菜单：

- 单次点按（20 s）→ 进入 **SAVE / LOAD** 存档界面（`out/step1_28.png`：SAVE/LOAD 两个页签、槽位列、光标手）；
- 连续点按 → 光标在槽位/页签间移动（`out/nav_50.png`、`out/ng_55.png` 里光标位置不同）。

说明触屏 → 官方 runner 的输入合成完全正常。下一轮要做的只是「把菜单点对」：
从标题进主菜单后选中 **New Game**（目前几次点按都落在 Load 页），然后用点按推进开场对白。

无签名 ipa 已用该修复重打（17,019,361 B，sha256 前 24 位 `f3f19b2c192b6c8f66748e67`，结构校验 0 项红）。

## 修复后的流程探索 + 交付物分发（2026-10-18 11:1x）

修复（不再伪造鼠标）后，交互已经可以走流程，但也暴露了「菜单点击位置」问题：

- 连续点按会进入 **LOAD（读档）界面**并停在那里（中点位置在 Load 页；`out/dl_48.png`）；
- 按 **B 键**会退回/重启流程（`out/back_52.png` 回到 Ysbryd Games 发行商 logo），说明手柄 B 被游戏收到；
- 单次点按有时直接进开场旁白（`out/tap_t23.png`：`A city that shouldn't exist…`），
  有时落在 attract——取决于点按时刻是否正好在标题交互态。

**结论**：输入链路已通（点按 + 手柄都生效）；剩下的是**点对菜单项**（New Game 的位置）
与 attract 时机的对齐。下一轮做法：先点按一次进入主菜单 → 立即截图 → 按截图上 New Game 的实际位置补点。

### 交付物分发（用户要求）
- 无签名 ipa 已放 iCloud：`Va11IOS-unsigned-20261018-1105.ipa`（17,019,361 B，sha256 f3f19b2c…）
- 游戏数据两份也放 iCloud：
  - `Va11IOS-data-EN/game.win`（原版，497 MB，sha256 e860d56e709c1883…）
  - `Va11IOS-data-CN/game.win`（汉化补丁版，497 MB，sha256 ff5220e0bc8e8d18…）
  - 真机：装 App 后放进「文件 → 我的 iPhone → VA-11 → save/game.win」

## 汉化版标题菜单点开了（2026-10-18 11:2x）

修复后继续探索菜单，关键收获：

- 中文标题菜单已能显示：`out/evidence_cn_title_menu.png`（`新游戏 / 读取 / 设置`，光标手在 `读取` 上）；
- 手柄 D-pad/A/B 都生效（B 会退回/重启流程，回到 Ysbryd 发行商 logo）；
- 但从标题进入后多次落到 **SAVE/LOAD 存档界面**（`out/ng6_44.png`）：该界面上有 SAVE / LOAD 两个页签、
  1–6 号槽位与右下角返回箭头，光标可移动；点按槽位/箭头只移动光标，未激活。

### 坐标映射（重要，后续可直接用）
App 是横屏，模拟器截图是竖屏（画面旋转 90°）。用「点返回箭头」校准出映射：

```
game_x = 1 - portrait_y
game_y = portrait_x
```

校准点：箭头在竖屏约 (0.78, 0.62) → 点 (0.38, 0.78) 时光标正好停在箭头上 ✓

据此推算中文标题菜单三项在**游戏坐标**的位置（竖屏 x≈0.73，y 分别 0.63/0.49/0.34）：

| 菜单项 | 竖屏 (px,py) | 游戏坐标 (gx,gy) |
|---|---|---|
| 新游戏 | (0.73, 0.63) | (0.37, 0.73) |
| 读取 | (0.73, 0.49) | (0.51, 0.73) |
| 设置 | (0.73, 0.34) | (0.66, 0.73) |

### 下一步
1. 进入 SAVE/LOAD 后先点**返回箭头两次**（第一次只移光标、第二次才激活的假设待证）回标题菜单，再点「新游戏」；
2. 若 SAVE/LOAD 其实是「新游戏选槽」流程，则直接点 **1 号槽**继续；
3. 记录每次点按后的截图，做成「状态 → 点击位置」的小表，避免再猜。

## 菜单点位第二轮：仍未点中「新游戏」（2026-10-18 11:3x）

按上一轮映射试了几组点位，结果都是进入 **SAVE/LOAD 存档界面**并停住（槽位/返回箭头只移动光标、不激活）：

| 跑的脚本 | 结果 |
|---|---|
| 点中心 → 悬停 (0.37,0.73) → 点 (0.37,0.73) | 进 SAVE/LOAD（`out/nw_60.png`） |
| 点中心 → 点返回箭头 (0.38,0.78) ×2 → 点 (0.37,0.67) | 仍在 SAVE/LOAD（`out/bb_50.png`） |
| 点中心 → 点 (0.375,0.735) → 点槽位 (0.385,0.80) ×2 → A×2 | 仍在 SAVE/LOAD（`out/sl_54.png`） |

**观察**：光标手会跟随我们点按的位置移动（说明坐标换算基本对），但「新游戏」这一项始终没激活；
`SAVE/LOAD` 界面的槽位点了也不走。两种可能：
1. 菜单里三项的**行位置**比我推算的更靠下/靠上（竖屏 x≈0.73 只是文字，实际热区不同）；
2. `SAVE/LOAD` 就是「新游戏 → 选存档槽」流程，空槽需要**双击/长按**或先切到 SAVE 页再选。

### 下一步（改成系统化扫描，不再凭推算）
写一个「扫描一次跑完」的脚本：在菜单区按 3×3 候选点位依次 hover+click（每点后由外层每秒截图），
把截图按内容分类（标题菜单 / SAVE-LOAD / 开场旁白 / 其他），命中「新游戏」的那一组点位即确定热区；
若全部落到 SAVE/LOAD，则直接研究该界面：先点 SAVE 页签、再点 1 号槽、再确认。

## 验收开关 DM_NO_TAP_A：点按不再补 A（2026-10-18 11:4x）

**又一个把前几轮误导的机制**：产品逻辑里「点按 = 推触点 + 补 A/Enter/Space + 帧同步点击」
（为的是「轻触或按 A 键开始」这类只认 A 的提示）。但在**菜单里**，这一补 A 会顺手激活默认项：

- 实测：单次点按后，过几秒画面自己跳到 **SAVE/LOAD**（读取页）——不是我们第二次点击造成的；
- 所以之前「点 (0.37,0.73) 想选新游戏却落到读取」很多次其实是**补的那个 A** 选了默认项。

新增 `DM_NO_TAP_A=1`（仅验收用，产品默认不变）：点按只推触点，不补 A/Enter/Space/帧同步点击。
用它跑了一次纯触点流程（`out/nh_26.png` 起）确认画面停在标题/进入菜单，可做干净的点位验收。

### 结论 & 下一步
- 之后所有**菜单点位验收**都必须带 `DM_NO_TAP_A=1`，否则补 A 会污染结果（这条要写进验收脚本默认参数）；
- 下一轮在 `DM_NO_TAP_A=1` 下重跑「点中心 → hover 菜单项 → 截图」，用 hover 高亮判定哪一格是「新游戏」，
  再点它；如果 hover 高亮不可见，就退回「逐个点位点击 + 每秒截图分类」。

## 真机 LiveContainer 闪退修复：宿主映像头解析（2026-10-18 11:3x）

用户真机（LiveContainer 环境）启动闪退，`Documents/boot.txt`：

```
[boot] 内嵌段 main: x0=0 W=0 x1=0 X 缺
[boot] 内嵌段 sdk / subsdk0 / subsdk1 同样全缺
[boot] SHELL-RED（载荷/游戏数据不全）
[dm] FATAL 内嵌节 __dmmainx0 / __DMmainW / __dmmainx1 缺失
```

**根因**：LiveContainer 这类侧载器把 App **加载在它自己的进程里**，此时 `_NSGetMachExecuteHeader()`
指向**宿主 App 的 Mach-O**，不是我们的映像 → 用主可执行头查 `__DM*W` 段自然全「缺失」，
装载器 FATAL 退出（代码/载荷本身没问题）。

**修复**：新增 `dm_host_image()`（`loader.c`）——遍历 `_dyld_image_count()` 的已加载映像，
优先返回**含 `__DATA,swhle`（HLE 表）或 `__DMmainW,__img`（内嵌段）** 的那个映像；
`loader.c` 的 `image_mh()`、`hle.c` 的 HLE 表查询、`main.m` 的载荷自检统一改用它。
找不到才回退 `_NSGetMachExecuteHeader()`，并把选择结果打进日志。

模拟器验证（正常主可执行环境）：

```
[dm] [boot] 宿主映像：主可执行（_NSGetMachExecuteHeader）
[boot] 内嵌段 main: x0=2899968 W=11190272 x1=131072 OK
... 四个模块全 OK → SHELL-OK → Entering main loop.
```

**新 ipa**（含该修复）已重打并放 iCloud：
`Va11IOS-unsigned-20261018-1132-livecontainer.ipa`，17,021,666 B，sha256 前 24 位 `14a4d8acddffb0f4e20f5a14`，结构校验 0 项红。

真机再试时若仍失败，请把新的 `boot.txt` 发我——第一行会打印「宿主映像：…」，
可以直接看出解析到的是主可执行还是按内嵌节定位。

## 纯触点模式下的菜单定位进展（2026-10-18 11:5x）

带 `DM_NO_TAP_A=1`（点按只推触点）继续定位，得到两条稳定结论：

1. **先点空白角落再点菜单项**：`click(0.12,0.15)`（画面左上空白）可以「进入主菜单但不选中任何项」，
   避免点中心时顺手激活「读取」跳到 SAVE/LOAD；
2. **「新游戏」热区基本确定**：再点 `(0.39,0.79)` 后，光标手正好停在「新游戏」文字上
   （`out/evidence_menu_hand_on_newgame.png`，光标在「新游戏」右侧，「读取」是黄色高亮=手柄选择位）。

但**激活仍未成功**：同一位置再点一次、或按手柄 UP+A，都没进入新游戏（画面停在菜单或又回 SAVE/LOAD，
`out/w_49.png`、`out/w_59.png`）。日志里只记录到触点，没有键位服务行（key 步骤不打日志）。

### 下一步
1. 在「手停在新游戏上」那一刻改用**只发 A（不推触点）**确认一次（避免触点抬起把选中清掉）——
   即 `hover` 定位后用 `key:A`，而不是 `click`；
2. 或者试**长按**（按住 600–800 ms）而不是 250 ms 点按；
3. 若仍不行，退回对照「读取」的点击路径（已知能进 SAVE/LOAD），看两者的差别在按下还是抬起。

## 菜单确认机制实验（2026-10-18 12:0x）

为定位「菜单如何确认」新增了 `DM_TEST_STEP` 的 `kbd:` 步（HID 键码注入，40=Return、82=Up…），
并做了一组实验：

| 尝试 | 结果 |
|---|---|
| 开菜单（点空白角落）→ 手柄 UP ×1~2 → 点空白/点 A | 菜单仍在（黄色高亮仍在「读取」，`out/y_56.png`） |
| 同上但用键盘 Enter / Up+Enter | 菜单仍在（`out/k_58.png`） |
| 开菜单后 hover 遍历 (0.30~0.44, 0.72~0.84) | 高亮不跟随 hover（`out/z1..z5.png`） |

**结论**：
1. 「读取」的黄色高亮是**手柄选择位**（不是鼠标 hover）；点击任意处会确认当前高亮项 → 这就是为什么点中心总进 SAVE/LOAD；
2. 但**手柄 UP/DOWN 没有移动高亮**（D-pad 位掩码已核对：UP=0x2000 与 libnx 一致，服务日志也已确认发出）；
3. 鼠标 hover 不改变高亮 → 该菜单**可能只把手柄的某个特定键**当作导航/确认（例如摇杆而非 D-pad，或 `PLUS`）。

### 下一步
1. 试**左摇杆**上/下（HLE 已支持左摇杆值 `g_in.lx/ly`，可用 `PK_LSU/PK_LSD` 伪键或直接注入摇杆值）来移动高亮；
2. 试 `PLUS / MINUS / X / Y` 作为导航键；
3. 若都不行，换思路：**直接构造一个存档文件**走「继续游戏」，绕开新游戏入口（需要先摸清存档格式，
   可先用一次游戏内保存生成样本——但要先进游戏，先有鸡还是先有蛋）。

## 真机「能进游戏但触摸没反应」排查（2026-10-18 12:1x）

用户真机（LiveContainer，新 ipa）反馈：**能进游戏，但触摸没反应**。boot 2.txt 关键行：

```
[boot] 宿主映像：按内嵌节定位（侧载器进程内加载）   ← 上一轮修复生效
[boot] 内嵌段 main/sdk/subsdk0/subsdk1 全 OK
[boot] SHELL-OK → Entering main loop.
[dm] [hid-read] 每秒读取 npad=28 touch=28 mouse=0 kbd=28   ← 触屏在轮询、鼠标按真机语义为 0
```

即：内核/HLE 侧一切正常，游戏侧也在读触屏；问题在**前端手指路径或菜单确认语义**。
注意模拟器上我们一直用 `DM_TEST_STEP` 直接调 `dm_touch_set`（绕过 UIView），
**真手指路径（UIView touches → pushTouches → dm_touch_set）从未被测过**，这是盲区。

本轮加了两件事（同 ipa）：
1. **前端触点日志**：`pushTouches` 里首次 6 次 + 每 60 次打 `[front] 触摸推 n 点 #0=(x,y) 视图=WxH 第 k 次`，
   用来判断「真机触摸到底有没有到 App」；
2. **窗口级兜底手势**：在 `UIWindow` 上挂 `UITapGestureRecognizer`，把点按按视图坐标归一化后走同一条注入路径；
   若 300 ms 内视图已收到真实触点则跳过（不重复触发）。用于侧载器把事件留在自己窗口层的情况。

新 ipa：`Va11IOS-unsigned-20261018-1159-touchdiag.ipa`（17,018,745 B，sha256 前 24 位 `fa7a75e8676d53f8e272fab1`，0 项红）。

### 下一步（等真机日志）
- 装新 ipa 后点几下，把 `boot.txt` 发回：
  - 若出现 `[front] 触摸推 …` → 触摸到达视图，问题在「菜单确认语义」（继续按模拟器结论调）；
  - 若只有 `[front] 窗口手势兜底 …` → 视图没收到，兜底手势接住了（功能可用，但坐标/缩放要再校准）；
  - 若两者都没有 → 侧载器把触摸完全拦在 App 之外，需要改用别的注入入口（例如 LiveContainer 的手势转发或外接鼠标/键盘）。

## 窗口兜底注入路径在模拟器验证通过（2026-10-18 12:2x）

把窗口级兜底抽成 `front_window_tap(nx,ny)`（手势与 `DM_TEST_STEP` 的 `wintap:x,y` 步共用），
在模拟器上直接验证这条注入路径：

```
[dm] [test] 单步脚本 at:8000;wintap:0.5,0.5;wait:3000;wintap:0.3,0.7
[dm] [front] 窗口手势兜底 (0.500,0.500)
[dm] [front] 窗口手势兜底 (0.300,0.700)
[dm] [test] 单步脚本执行完毕
```

→ 归一化、日志、`dm_touch_set` 注入与「点按补 A」这条兜底链在模拟器上是通的；
真机上只要窗口手势能收到事件（日志出现 `[front] 窗口手势兜底`），触摸就能进游戏。

**不需要重出 ipa**：上一份 `-touchdiag`（`fa7a75e8…`）已含手势兜底与触点日志，本轮只是加了
`wintap` 测试步（验收用）并验证兜底实现本身。

## 真机触摸无反应：根因找到（抬手从不推送）（2026-10-18 12:3x）

用户 boot 3.txt 证明**触摸确实到 App 了**：

```
[dm] [front] 触摸推 1 点 #0=(0.510,0.301) 视图=1280x720 第 1 次
[dm] [front] 触摸推 1 点 #0=(0.510,0.301) 视图=1280x720 第 2 次
...
[dm] [hid-read] 每秒读取 npad=28 touch=28 mouse=0 kbd=28
```

关键观察：**日志里从来没有 `触摸推 0 点`**。原因在 `pushTouches`：

```objc
for (UITouch *t in touches) { if (n >= 16) break; all[n++] = t; }
```

抬手（touchesEnded）时 `event.allTouches` **仍然包含那根已经抬起的手指**，于是每次都推 n≥1：
游戏侧永远看到「一根一直按着的手指」，后续点按都被视为「已经按着」，
连「点按补 A」也不会触发（`n == 0 && g_was_down` 分支永远不成立）→ 真机触摸完全没反应。

模拟器上一直用 `DM_TEST_STEP` 直接 `dm_touch_set(NULL,0)`，所以这个 bug 只在真手指路径暴露。

**修复**：只收集 `phase != Ended/Cancelled` 的手指；抬手时 n 变 0，正常推送抬起并补 A/点击。
另加一行 `[front] 点按抬手 → 补 A/点击 (x,y)` 日志，方便真机验证抬手链路。

新 ipa：`Va11IOS-unsigned-20261018-1229-touchfix.ipa`（17,019,157 B，sha256 前 24 位 `fd7e87e6ad93743a2fdf1355`，0 项红）。

## 触摸已可用；「新游戏后黑屏」根因：GM 运行时报错（2026-10-18 12:5x）

用户真机（boot 4.txt）：触摸已能点进「新游戏」，随后黑屏。日志里找到 GameMaker 运行时错误：

```
ShowMessage:
ERROR in
action number 1
of Other Event: User Defined 0
for object obj_textbox:
trying to index a variable which is not an array
at gml_Script_textbox_loadbox
```

关键线索（模拟器复现与对照）：

| 语言 | 数据 | 结果 |
|---|---|---|
| `DM_LANG=en-US` | 汉化补丁 game.win | 播完开场旁白后报上述 ERROR → 黑屏（`boot 4.txt` 同款） |
| `DM_LANG=en-US` | 原版 game.win | 同样报 ERROR（说明**不是汉化补丁**的问题） |
| `DM_LANG=ja-JP` | 汉化补丁 game.win | 110 秒无 ERROR，画面停在日文「物語は、ここから始まる。」 |
| `DM_LANG=fr-FR` | 汉化补丁 game.win | 40 秒无 ERROR（待更长时间复测） |

→ 症状与**语言相关**：文本引擎按语言装载台词文件（game.win 里能看到
`scripts/eng/1.2/anna.txt`、`scripts/eng/1.2/pro1.txt`、`scripts/jp/testroom.txt` 等内部文件名），
英文路径下 `textbox_loadbox` 读到的数据形状不对，索引非数组即报错。

### 待办（下一步）
1. 加文件层日志（`file_text_open_read` / 读取行数 / 首行内容），确认英文台词文件是否能打开、读到多少行；
2. 检查 `scripts/eng/1.2/*.txt` 在 game.win 内部的文件表里是否存在（名字已看到，需确认可读）；
3. 若英文文件确实读不到，尝试把 romfs 里根目录的 `anna.txt` / `pro1.txt`（原始 romfs 里有，我们还没解出来）
   放到 `Documents/save/`（= `host:/`），再复测；
4. 语言作为对照：`ja-JP` 无错误可作为「文本引擎可工作」的基线。

## 附：测试脚本注意（用户指出）
之前模拟器脚本常点屏幕中央，菜单里等于确认默认项「读取」。后续脚本一律：
先点画面左上空白进入菜单，再点**左侧「新游戏」**（游戏坐标约 `(0.37, 0.79)`）。

## 「新游戏后黑屏」定论：汉化补丁与本体 1.2.3.0 不兼容（2026-10-18 13:1x）

干净对照实验（模拟器，同代码，`DM_LANG=en-US`，长按 Enter 推进）：

| 数据 | 时长 | GM 报错 | 画面 |
|---|---|---|---|
| **汉化补丁** game.win（标称 1.0.1） | 90–110 s | **有**：`obj_textbox` / `gml_Script_textbox_loadbox` 索引非数组 | 播完开场旁白后黑屏 |
| **原版** game.win（1.2.3.0） | 130 s | **无** | 标题正常（`Good Bye Miss Bartender 1.2.3.0`），可推进 |
| 汉化补丁 + `zh-Hans` | 75 s | 无 | 显示**日文**（补丁没有中文槽，回退日文） |
| 汉化补丁 + `ja-JP` | 110 s | 无 | 日文「物語は、ここから始まる。」 |

另外用 `DM_FS=1` 记录的文件打开清单：全程只打开 `host:/game.win`、`host:/preselected_user`、
`host://Waifu Preferences.txt` —— **没有任何 scripts/*.txt 外部文件被打开**，
说明台词是编在 game.win 内部文件表里的，不存在「缺 romfs 文件」的问题。

**结论**：移植与运行环境都没问题；黑屏是**汉化补丁（1.0.1）在 1.2.3.0 本体上跑出的 GML 脚本错误**。
之前那条「原版也报错」的记录是日志未清干净的误判，已用干净实验推翻。

### 可选路线
1. **先用原版英文通关/验证**：`game.win` 换回原版（iCloud `Va11IOS-data-EN/game.win`，sha256 `e860d56e…`）；
2. **补齐版本**：找 1.2.3.0 对应的中文补丁，或改用 1.0.1/1.0.0 本体 + 现补丁（本体版本必须与补丁一致）；
3. 若坚持在这个补丁上修：需要反查 `textbox_loadbox` 期望的数组（YYC 原生码，成本高，不建议优先）。

## 原版英文数据跑通开场（2026-10-18 13:2x）

把 `game.win` 换回原版（`e860d56e…`）后，用键盘 Enter 连续推进，模拟器完整走过：

- 标题「Good Bye Miss Bartender 1.2.3.0 / Tap or press A to start」；
- 开场旁白（英文）；
- **酒吧内景旁白**「…but that's a mouthful, so we just call it Valhalla.」（`out/evidence_en_bar_narration.png`）；
- 全程 **0 条 GM 报错**（`out/long_boot.txt`），游戏循环、渲染、音频都正常。

对照汉化补丁数据同一时刻：播完开场旁白后 `obj_textbox` 报错 → 黑屏。
→ 再次确认：**移植可用，问题在补丁与本体版本不匹配**。

## 原版英文标题菜单与 New Game 入口打通（2026-10-18 13:4x）

换回原版英文数据后终于看清标题菜单（`out/evidence_en_title_menu.png`）：

```
New Game      ← 竖屏左下（游戏坐标约 (0.375, 0.735)）
Load          ← 竖屏中间（黄色高亮 = 默认选中项）
Settings      ← 竖屏右上
```

- 之前所有脚本「点一下就进 LOAD」的原因：**默认高亮是 Load**，点任意处都会确认当前高亮项；
- 正确姿势：**先点 New Game 位置把高亮移过去，再点一次确认**（两次点击），实测进入
  **「Thank you for playing VA-11 Hall-A! ... Press A or tap to continue」欢迎对话**
  （`out/evidence_en_newgame_welcome.png`）——即成功进入新游戏流程；
- 全程 0 条 GM 报错。

### 下一步
1. 从欢迎对话继续推进（点按/A）进入开场旁白与第一天剧情，抓「进入酒吧/调酒」证据；
2. 自动脚本注意：每次点按都有 **250 ms 按住 + 补 A**，连续点按容易在「菜单重新出现」时误确认 Load；
   推进对白时用「间隔 5 s 以上的单次点按」更稳。

## 标题菜单的高亮/确认机制（2026-10-18 13:5x）

进一步实验（原版英文数据）：

1. **hover 会移动黄色高亮**：`hover (0.375,0.735)` 后截图显示 **New Game 变成黄色**、手形光标停在该项上
   （`out/hv2_39.png`）——之前 hover 不生效是坐标偏了（用了 0.66/0.78 等旧值）；
2. 但**紧接着点该位置仍然是进 LOAD**（`out/hc_35.png`、`out/ngA_54.png`）：说明「黄色高亮」与
   「确认时实际选中的项」不是同一个状态——点击/补 A 确认的是**手柄选择位（仍是 Load）**，
   hover 只改视觉高亮；
3. 之前用**键盘 Enter 连按**时反而能直接进新游戏并推进到开场/酒吧旁白（`out/long_120.png`），
   说明「确认」走的是手柄 A/键盘这条通道。

### 结论与下一步
- 模拟器自动化：**用键盘 Enter 起新游戏 + A 推进对白**最稳；鼠标点菜单项只能改高亮，不能改选中项；
- 真机上用户能点进 New Game：因为真实点按 = 触摸 + 补 A，且此时手形光标已在落点，
  与我们纯粹 hover+click 的时序不同（待真机再验证一次细节）；
- 若要支持「纯触摸选菜单」，需要在 HLE 里把「鼠标位置」同步给手柄光标选择位（读 `dm_cursor` 的
  UI 代号/坐标后当方向输入），这是下一步可选改动。

## 点按顺序修正：先鼠标点击、再补 A（2026-10-18 14:1x）

前几轮所有「点 New Game 却进 Load」的现象有一个共同解释：
**点按产品的补键（A/Enter/Space）与鼠标点击同一拍发出，游戏在收到 A 的那一拍确认的是手柄当前选择位（Load）**，
鼠标点击还没来得及把选择挪到落点。

改动（`main.m` 的 `tap_a_pulse_at`）：
1. 先发帧同步鼠标点击（真实落点）；
2. **延迟 450 ms** 再补 Enter/Space 与 6 拍 A —— 给点击一帧以上的时间先改变菜单选择。

另加测试步 `mclick:x,y`（只 hover + 帧同步点击，不推触点、不补 A），用于把「鼠标坐标系」与
「触点坐标系」分开验证。

模拟器现状：坐标映射本身仍有偏差（hover 能高亮到 New Game，但同一坐标的纯鼠标点击会退到标题/进 Load），
说明**触点坐标到游戏鼠标坐标之间还有一层变换没摸清**；真机侧用户点按是正确的（能进 New Game），
所以这一版按「先点击后补键」发出去，请真机验证是否更稳。

新 ipa：`Va11IOS-unsigned-20261018-1417-tapclick.ipa`（17,019,621 B，sha256 前 24 位 `e9ca541107bf4dbd686e2f93`，0 项红）。

## 鼠标通道对照实验（2026-10-18 14:3x）

用 `DM_MOUSE=1`（恢复「把触点报成鼠标设备」的旧行为）+ 纯鼠标点击 New Game：

- 结果：**标题卡住不动**（`out/mo_39.png` 仍是 "Tap or press A to start"）——与之前结论一致：
  报出鼠标设备会让官方 runner 走鼠标路径并吃掉触屏合成；
- 所以产品默认保持 `GetMouseStates → 0`（真机语义）不变。

同轮把坐标链再核了一遍（用「手形光标落点」当标尺）：

| 我们发的点（游戏坐标） | 手形光标实际落点（游戏坐标） | 结论 |
|---|---|---|
| (0.25, 0.25) 附近的点击 | (0.38, 0.78) 类位置 | 落点**跟随我们发的坐标**，说明触点↔鼠标坐标变换是我们这套映射能对上的 |

结合上一轮：
- `hover (0.375,0.735)` 能让 **New Game 变黄**、手形光标停在该项（`out/hv2_39.png`）；
- `DM_NO_TAP_A=1` 下在同一位置纯点击：**菜单不动**（没有 A 就没有确认）；
- 带 A 时：确认的是**手柄选择位**（仍是 Load）→ 进读档页。

→ 结论：**触摸能移动光标/高亮，但「确认」只认可手柄 A 的当前选择位**，而手柄选择位我们无法用触摸/鼠标改变。
真机上用户能点进 New Game，说明真机路径与我们模拟器注入的差异在于「点位时序/释放」，
所以下一步以真机反馈为准（已发 `-tapclick` 包：点击先行、补键延迟 450 ms）。

## 菜单项坐标实测 + 落点按住改动（2026-10-18 15:4x）

用像素分析量了英文标题菜单（`out/ng_47.png`，竖屏 1206x2622）：

| 元素 | 竖屏中心 | 换算游戏坐标 |
|---|---|---|
| New Game（白） | (0.750, 0.63) | (0.37, 0.75) |
| Load（黄，默认高亮） | (0.748, 0.497) | (0.503, 0.748) |
| Settings（白） | (0.754, 0.36) | (0.64, 0.75) |

→ 之前用的 (0.375,0.735)/(0.37,0.79) 与实际 (0.37,0.75) 差 1–4%，**不是坐标问题**。

新改动（`tap_a_pulse_at`）：**抬手后把落点重新按住 1.3 s**，在按住期间补 Enter/Space/6 拍 A。
动机：runner 的 `device_mouse` 只在触屏有活动触点时停在落点；一抬手就回到默认点，
于是后面的 A 又确认默认项（Load）。按住落点补 A，确认应落在落点那一项。

模拟器结果：仍进 SAVE/LOAD（`out/hp_41.png`）——说明模拟器里「A 确认的是手柄选择位」这条仍是硬的，
落点按住不足以改变它。改动保留（对真机时序可能有效，待真机反馈），新包：
`Va11IOS-unsigned-20261018-1546-holdpoint.ipa`（17,019,157 B，sha256 前 24 位 `699d70997620c624bfe1515f`，0 项红）。

## 真机 boot 5.txt：黑屏就是汉化补丁的 textbox 报错（2026-10-18 15:0x）

用户真机点 New Game 后黑屏（有声音、无点击反馈、画面/声音卡顿）。boot 5.txt 关键行：

```
[dm] [hid-read] 每秒读取 npad=28 touch=28 mouse=0 kbd=28      ← 前 28 秒一切正常
ERROR in
action number 1
of Other Event: User Defined 0
for object obj_textbox:
trying to index a variable which is not an array
at gml_Script_textbox_loadbox                                 ← 与模拟器 CN 补丁数据完全同一条错误
（之后 hid-read 停止 = 主循环卡死，所以黑屏）
```

即：**真机当前用的仍是汉化补丁的 game.win**，所以复现了模拟器里同样的
`textbox_loadbox` 错误 → 主循环停住 → 黑屏（但音频线程还在跑，所以有声音）。

### 处理
1. 把 `game.win` 换成 **原版英文**（iCloud `Va11IOS-data-EN/game.win`，sha256 `e860d56e…`）；
2. 换完再点 New Game：模拟器上原版数据同流程 0 报错、能推进到开场/酒吧旁白；
3. 中文要等「匹配 1.2.3.0 的补丁」或「换 1.0.1 本体」，当前补丁在这版本体上必崩。

### 顺带记录：音频撕裂/卡顿
真机反馈「画面和声音有迟钝、声音撕裂」。本轮先不处理——先把 textbox 报错解决，
再在能正常进游戏后单独看音频（`audio::OpenAudioOut` 已正常打开、双声道真出声；
撕裂可能与 LiveContainer 下的调度/缓冲有关，届时用 `DM_AUDIO_*` 诊断与缓冲加大试）。

## 自动推进终于可靠（kbdrep）+ 原版数据清存档后 0 报错（2026-10-18 16:0x）

**关键工具修正**：标题/对白只认**按下沿**，之前用「一直按住 Enter」只产生一次边沿，所以时好时坏。
新增 `DM_TEST_STEP` 的 `kbdrep:<键码>,<次数>,<间隔ms>[,<按住ms>]`（连续按下-抬起），此后自动推进稳定：

```
at:22000;kbdrep:40,40,2500,180
→ 80 s 时已在酒吧内景、英文旁白「…but that's a mouthful, so we just call it Valhalla.」（out/kr_80.png）
→ 全程 0 条 GM 报错
```

**存档干净时的对照**：清空 `Documents/save/` 里除 `game.win` 以外的所有内容
（`Settings/`、`Waifu Preferences.txt`、`preselected_user` 等），再用原版英文数据跑：
0 报错、hid-read 连续 158 秒不停、游戏自己重建设置目录。

→ 说明真机「英文标题 + 点 New Game 后黑屏」很可能不是版本不匹配，而是**上一次汉化版运行留下的存档/设置数据**
被 1.2.3.0 读取时触发了 `textbox_loadbox`。**处理：清掉 save 目录里除 game.win 之外的所有东西再启动。**

## 用户在模拟器复现黑屏 → 拿到完整调用栈（2026-10-18 16:1x）

用户在模拟器上亲手点 New Game，复现黑屏；`Documents/boot.txt` 里拿到**完整 GM 调用栈**：

```
ERROR in action number 1 of Other Event: User Defined 0 for object obj_textbox:
trying to index a variable which is not an array
at gml_Script_textbox_loadbox
stack frame is
gml_Script_textbox_loadbox
gml_Object_obj_textbox_Other_10
called from - gml_Script_textbox_create
gml_Script_day0control
gml_Script_daycontrol
gml_Object_dialog_control_Create_0
```

即：**第一天剧情 `daycontrol` 创建对话框时**，`textbox_create → textbox_loadbox` 里索引了非数组。
之前的「原版数据 0 报错」跑法（长按/连按 Enter）**根本没走到这个场景**（日志里没有 `dialog_control`），
所以那条结论作废——这不是汉化补丁或存档的问题，而是**点按进入新游戏后、第一个对话框创建时的移植侧问题**。

同时确认：我们的合成点击路径（`DM_TEST_STEP click`）在模拟器里仍落到 LOAD，无法复现该场景；
只有**真实触摸**能走到 day0 对话框。所以修复验证必须靠真机/真实触摸。

### 本轮改动（降低点按强度，排除「补键过猛」）
- 撤掉上一轮「抬手后按住落点 1.3 s」；
- 补键从 **6 拍 A** 降到 **2 拍 A**（间隔 0.5 s）：真实玩家一次点按只该产生一次确认，
  连拍容易在对话框创建前后把确认/状态吃掉。

新包：`Va11IOS-unsigned-20261018-1401-gentletap.ipa`（17,019,700 B，sha256 前 24 位 `dfce00b102494c4dbfa451cb`，0 项红）。

### 下一步（若仍黑屏）
需要在 `textbox_loadbox` 失败点取证：要么在 HLE 里拦截并打印触发它的**输入状态**（鼠标按下/键盘/触屏），
要么导出 `game.win` 里 `textbox_loadbox` 的 YYC 原生码反查它索引的全局数组来源。
## 社区同类项目的做法与对本案的启示（2026-10-18 15:0x）

用户提示：d2r 发布后有很多同类移植项目，应参考别人遇到的问题。检索结果：

- **nxnative**（`seedds/nxnative`）：把 d2r-mobile 的通用部分（NSO 改写器 / Horizon HLE 宿主 / NVN→Metal / iOS 外壳）
  抽出来做成「一个 NSP 文件夹 → 一个 ipa」的通用流水线，已跑通马力欧惊奇、火纹 Engage、密特罗德、十三机兵、
  3D 世界、旷野之息、织梦岛。它的 `docs/agents/03-bringup.md` 是一份**故障目录**（症状 → 根因 → 修法）。
- 该目录里与我们高度相关的几条：
  1. **「IL2CPP 打不开 global-metadata.dat」→ 游戏先用 `nn::fs::IsMounted("rom")` 判断，SDK 自己的 IsMounted
     读的是宿主从未填过的挂载表**；修法：宿主按自己的挂载表回答 IsMounted。**我们没有实现 IsMounted**，值得补齐；
  2. 「文件找不到的噪声」：DM_FS=1 下大量 `fs … 不存在` 是游戏在探测可选路径，只有「缺失后紧接失败」才算问题；
  3. **iOS 独有爆音**：RemoteIO 默认按会话 I/O 缓冲（约 21 ms / 1024 帧）回调，而渲染侧只维持约 20 ms 在飞，
     每次回调差一点被补零 → 每秒几十次断口；修法是 `setPreferredIOBufferDuration:0.005` + 48 kHz。
     **本轮已照此修掉**（`front_ios.m`），正好对上用户反馈的「声音撕裂」；
  4. 「新标题先做静态普查：列出 main 的 nn:: 导入里没有任何宿主钩子命名的那些」→ 本轮写了
     `tools/import_census.py` 做同样的事；
  5. iOS 打包阶段：`env.txt` 支持运行期开关（免重打包改 DM_LANG 等）、日志 `log.txt`/`log.prev.txt` 约定。
- 另一条 d2r-mobile 的 README 强调：**RomFS 要放进 app**（dm/ios 里带 RomFS）。我们的 VA-11 包目前只带 game.win，
  若该作的台词/资源在 RomFS 里，这就是缺口（下一步核对）。

### 本轮改动
- `front_ios.m`：音频会话加 48 kHz + 5 ms 首选 I/O 缓冲（修 iOS 爆音/撕裂）；
- `tools/import_census.py`：导入 vs 宿主钩子普查工具（找出没有任何宿主实现命名的 nn:: 导入）。

新包：`Va11IOS-unsigned-20261018-1507-audiofix.ipa`（17,019,978 B，sha256 前 24 位 `36675623edbeb634379c419c`，0 项红）。

## 确定性复现脚本：day0 对话框崩溃（2026-10-18 15:0x）

**突破：不需要真人点按也能复现了。** 关键在菜单默认高亮是「Load」——对 New Game 位置连点 4 次
（第一次开菜单，后几次才落到项上）就能进 New Game，随后稳定触发同一条报错：

```
tools/repro_day0.sh 80
→ GM 报错数: 1
→ day0 栈: 1
   gml_Script_textbox_loadbox
   gml_Object_obj_textbox_Other_10 ← gml_Script_textbox_create
   gml_Script_day0control ← gml_Script_daycontrol ← gml_Object_dialog_control_Create_0
```

本轮据此排除/确认的事实：

| 假设 | 实验 | 结论 |
|---|---|---|
| 语言相关 | `DM_LANG=en-US / en-GB / ja-JP` 各跑一遍 | **全部报错** → 与语言无关（此前「ja 不报错」是 attract 模式，不是 day0） |
| 存档脏 | 清空 save 只留 game.win | 仍报错 → 与存档无关 |
| 挂载状态查询 | 实现并记录 `nn::fs::IsMounted` / `detail::GetMountName` | **游戏一次都没调用** → 不是这条 |
| 目录枚举 | `OpenDirectory` 也记日志 | 无任何目录枚举 |
| 缺台词文件 | 记录全部 OpenFile / OPENDIR / 失败 | 只有 `game.win` 与 `Waifu Preferences.txt`，**没有失败打开** |
| 数据文件读取 | 记录数据文件前 60 次读取 | **一次性整读 520,720,771 字节**（off=0 全量），之后不再读 → 台词数据在内存里 |

也就是说：台词字符串确实在 `game.win` 内（`0xb45xxx–0xb8xxxx` 一带能直接看到中英文旁白原文），
数据也整块读进内存了；问题出在**游戏自己的 GML 解析/索引**，而不是「缺文件」。
`textbox_loadbox` 附近的字符串给出它用的变量：`file_name`、`temp_fname`、`temp_text_pointer`、
`temp_chr`、`temp_textbox`、`start_pointer`、`pointer`。

### 下一步（下一轮做）
1. 在 main 模块里定位「数组越界/非数组索引」的运行时检查函数（YYC 原生码），在检查点记录**数组指针与下标**，
   直接看出是哪个变量；
2. 若不便插桩，退而求其次：把 `DM_TEST_STEP` 换成「点开 Settings/其它菜单项」对照，确认只有对话框路径崩；
3. 每轮都用 `tools/repro_day0.sh` 做回归（不再需要用户手动点）。

## 定位到「索引非数组」的运行时检查函数（2026-10-18 15:2x）

用 capstone 在 `main` 模块里反查报错文本 `trying to index a variable which is not an array`（main+0x3206fb）的引用，
找到唯一一处：`main+0x18110`（adrp/add 取串）→ `bl main+0x1ac50`（报错格式化）。

该函数入口 **`main+0x1809c`**，从序言可以读出它的参数约定：

```
0x1809c: stp x29, x30, [sp, #0x30]
0x180a4: mov x20, x1              ; x1 = 变量描述符（descriptor）
0x180a8: ldr w8, [x20, #0xc]      ; 取标签
0x180ac: and w8, w8, #0xffffff
0x180b4: cmp w8, #2               ; 2 = 数组？
0x180b8: b.ne 0x18104             ; 不是数组 → 走报错
0x180bc: mov w8, #-0x80000000     ; 0x80000000 = 「undefined 下标」哨兵
0x180c4: cmp w2, w8               ; x2 = 下标
```

也就是说：**x1 指向的值描述符、+0xc 的低 24 位就是类型标签**（2 = 数组），x2 是下标。
我们的报错链里恰好有 `main+0x1811c` 这一帧（就是该函数报错后的返回点），说明确实是这个检查点触发的。

### 下一轮要做的插桩（最直接的一条）
在该检查点（`main+0x1809c` 入口）记录 **x1（描述符指针）、x2（下标）**，并打印 `[x1+0xc]&0xffffff` 的实际标签；
这样能立刻看出 `textbox_loadbox` 索引的是哪个变量、它当时的真实类型（0=undefined/1=字符串/3=结构体…）。

脚本化路径：
1. `~/va11-work/patched/main.cuts.tsv` 已有「按原始字节校验的代码补丁」机制（格式：偏移 / 原字 / 新字 / 全 / 说明），
   可在构建期把检查点改成跳到宿主钩子（宿主地址由 loader 的 gate 机制在装载期写入）；
2. 或者先走「零补丁」路线：在 `dm_in_show_message` 里沿 fp 链定位 `LR==main+0x1811c` 的帧，
   把该帧保存的 x20（描述符）读出来（描述符在栈上，读取前用 `g_as…g_as+RESERVE` 范围做校验），
   直接打印类型标签 —— 这条不需要改客体代码，优先试它。

## 插桩结果：报错时数组检查帧的描述符候选（2026-10-18 15:4x）

在 `dm_in_show_message` 命中时新增插桩（`loader.c`）：
1. 找到返回点落在 `main+0x1809c..0x18300` 的那一帧（就是「索引非数组」检查函数）；
2. 用 `setjmp`+临时 SIGSEGV/SIGBUS 处理器做**安全读**（`dm_host_readable`，iOS 模拟器 SDK 没有 `mach_vm_region`）；
3. 扫该帧栈窗口里「像 GML 值描述符的指针」，读 `[p+0xc]&0xffffff` 类型标签 + 前 4 个字 + 可能的文本。

本轮实测（`tools/repro_day0.sh`，稳定复现 errors=1）：

```
[va11] 数组检查帧 槽-128 描述符 ... 标签=1       内容=... 文本=""
[va11] 数组检查帧 槽-112 描述符 ... 标签=16777215（0xffffff，非堆值标记）
[va11] 数组检查帧 槽-96  描述符 ... 标签=0       内容=0000000000000002 ...
[va11] 数组检查帧 槽-88  描述符 ... 标签=0
[va11] 数组检查帧 槽-80  描述符 ... 标签=1       文本="h"
[va11] 数组检查帧 槽-64  描述符 ... 标签=16777215
```

结合反汇编出的检查函数语义（`x0`=目标值、`x1`=源值描述符、`x2`=下标；
`[x1+0xc]&0xffffff`：2=数组、1=字符串、0=undefined/数字）：

- 报错说明被索引的变量**类型不是数组**，候选里出现 **标签 0（undefined）** 的描述符，最符合
  「初始化没跑/没建数组」的情形；
- 但栈窗口里有多个候选，还需把「检查函数的调用者帧」精确定位（该函数不保存 x20，x20 由调用者保存）。

### 下一轮
1. 把插桩扩展成「沿 fp 链逐帧扫、带帧号与 LR 偏移」，锁定检查函数**调用者**保存的 x19/x20；
2. 顺带在 `textbox_loadbox` 入口记录 `file_name`（GML 全局字符串）的值 —— 若为空/undefined，
   就说明是「依语言/依进度选台词文件」的那一步没跑起来（而不是文件读不到）。

## 观测门命中：抓到「非数组索引」的确切现场（2026-10-18 16:0x）

走「改写器离线插观测门」的路子（`dm/tools/patch_nso.py` 的 OBS 表 + 宿主 `gate_obs_set`）：

1. 反汇编确认数组取值 helper 的**真实函数入口是 `main+0x18090`**（`str x23,[sp,#-0x40]!` 起，依次保存 x23/x22/x21/x20/x19；
   之前在 0x1809c 找到的只是函数内的第二段序言）；
2. 在该入口注册 OBS 门 9（`OBS_ARRAY`），参数约定：`x0`=目标值、`x1`=源值描述符、`x2`=下标，
   源描述符类型标签 `[x1+0xc]&0xffffff`（2=数组），`w2==0x80000000` 表示 undefined 下标；
3. 顺手把两条「历史产物依赖的剪口」修好：`0xc54` 那条与当前 exefs/main 不匹配，改成默认关闭
   （`DM_VA11_PRESELECT_STR=1` 才启用），这样用本工作树重新改写四个模块能**逐字节复现现有产物**
   （main/sdk/subsdk0/subsdk1 的 patched.bin sha256 全部相同，作为「改写器没有回归」的证据）。

**本轮实测（`tools/repro_day0.sh`，稳定复现）**：

```
[dm] main: gates 1 patch_off 0xd70000
[dm] VA-11：数组索引观测门已挂（OBS_ARRAY）
[dm] [va11] 非数组索引：源描述符 0x3f804e970 标签=16777215 下标=0 目标=0x3f814bef0 调用者=0x1154ae7c8
     描述符内容=0000000000000000 00ffffff78787878 3ff0000000000000
```

解读：
- **只命中一次**，并且正好是报错那一次 → 这就是 `textbox_loadbox` 崩溃的确切现场；
- 源值的类型标签是 **0xffffff（-1，未初始化/无效类型）**，不是数组（2）；
- 描述符内容里能看到 `3ff0000000000000`（double 1.0）与 `78787878`（ASCII "xxxx"），
  说明这个「值」本身是普通数值/临时值，而代码却拿它当数组下标读取；
- `调用者=0x1154ae7c8` 是 GML 编译代码（在 runner 载入的 game.win 代码区，不在我们的模块表里）。

### 下一轮
1. 在门回调里安全 dump 调用点前后 ~64 字节代码，离线反汇编 → 找出它读的是哪个全局/局部槽
   （紧接着就是 `bl main+0x18090`，前面的 `ldr x1, [xG, #off]` 能直接给出变量槽位）；
2. 结合 `day0control` 的初始化流程，确认那个变量**本该在哪一步被建成数组**（多半是依语言/依进度的
   台词表初始化，或存档里的 data 结构），从而定位是移植侧哪个服务返回值导致的。

## 现场取证进阶：GML 侧调用链与代码 dump（2026-10-18 16:3x）

观测门回调里新增两样取证：
1. **调用点代码 dump**（`vm_read_overwrite`，因为客体代码页可能是 exec-only，直接读会失败）；
2. **GML 侧调用链**（沿 `x29` fp 链打原始返回地址；GML 编译代码不在我们的模块表里，所以是裸地址）。

`tools/repro_day0.sh` 稳定复现后的输出（一次运行，只命中一次）：

```
[va11] 调用点代码 dump（基址 0x115daa788）: ...fd7bbfa9 7ed03bd5 bdfeffd0 bd0f40f9 de031d8b de0340f9 fd0340f9 c0033fd6
[va11] GML 调用链：0x115040ff4 <- 0x115040c20 <- 0x1150310b8 <- 0x1150311cc <- 0x1151ba57c <- ...
[va11] 非数组索引：源描述符 0x3f804e970 标签=16777215 下标=0 目标=0x3f814bef0 调用者=0x115daa7c8
```

反汇编结论：

- 调用点是一个**通过 TLS（`tpidrro_el0`）+ 函数指针表**的间接调用桩：
  `mrs x30, tpidrro_el0 → adrp/ldr → add → ldr x30,[x30] → blr x30`；
- 再往上一帧（真正调用 helper 的 GML 函数）里能看到：
  `mov x1, x25` → `blr x22`，即**源值就是 GML 局部/临时值 x25**；
- x25 指向的是一个 **16–0x20 字节的 GML 值临时结构**，其中 `[+0xc]` 的类型标签被 `str wzr` 清成 0、
  实测报错时是 **0xffffff（-1，未初始化）**，内容里还留着 `3ff0000000000000`（double 1.0）与 "xxxx"；
- 结合 helper 的语义（`x1`=源值描述符、`x2`=下标、下标 0 是有效下标 → 报错），
  **最合理的解释是：这个被索引的值是一个「未定义/未初始化」的 GML 值**，
  即 `textbox_loadbox` 拿到的实参（或它内部依赖的全局）根本没被赋值。

### 下一轮（两条并行）
1. 用同样的办法把 **`textbox_loadbox` 入口**也插一个观测门（先按第一次调用时的调用者判断它的入口地址），
   记录它拿到的 `argument` 指针与 `argument_count`，直接确认「是不是根本没收到实参」；
2. 若是实参缺失，顺着调用者（`textbox_create` 那条 GML 代码）反查实参来源的那个全局槽，
   对照 `day0control` 的初始化顺序找出「本该赋值却没赋值」的那一步。

## 调用链第 2 帧反汇编：是运行时引用计数 helper，不是 GML 调用者（2026-10-18 16:5x）

把帧 1 dump 加长到 0x200 后反汇编，看到的是 **GameMaker 运行时自己的值管理 helper**
（对 `[x21+0xc]` 的类型标签做 2=数组 / 1=字符串 / 其余 的分支，`0xffffff` 魔数、`mov x8,#0x600000006`、
引用计数与释放、末尾 `ldp x29,x30` 收尾）。

结论：**fp 链上的前几帧是运行时 helper**，真正的 GML 调用者（`textbox_create → textbox_loadbox` 的那一层）
在链的更深处；而链深处的帧已经超出我们能可靠 dump 的范围。

因此「靠 fp 链找 GML 调用点」这条路收益有限，下一轮换更直接的办法：
1. 用**观测门的参数**判定被索引的值类型（已确认：标签 0xffffff、下标 0），
   再把观测门放宽成「记录前 8 次数组取值调用的 (源标签, 下标, x25 等)」，看这次错误前后值的演化；
2. 找到 `textbox_loadbox` 的代码地址后，在它入口再插一个门（现在是 1 次/轮的调试，地址可从
   「调用它的 stub 目标寄存器 x22」在门回调里顺手打出来 → 下一轮加这个记录）；
3. 若仍难以定位，改从数据侧验证：把 `game.win` 里 `gml_Script_textbox_loadbox` 符号表条目附近的
   名字表（`gml_Object_obj_textbox_*`、`textbox_*` 变量名）与代码段做交叉索引。
