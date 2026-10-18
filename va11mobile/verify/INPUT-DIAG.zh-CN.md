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
