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
