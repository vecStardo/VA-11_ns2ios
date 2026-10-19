# HD 震动（设置页）实现与验证

> 结论：**宿主链路已接通并在模拟器上验证触发**（`[hid-vib]` + `[haptic]` 日志各一条/次点击）；
> 真机（LiveContainer）已由用户实测确认有震动。arm64 无签名出包结构校验 0 项红。

- 日期：2026-10-19
- 环境：macOS / Xcode 26.3 / iPhone 17 Pro 模拟器 `VA11-User`（`DM_OPMODE=0` 掌机）；
  arm64 Release 无签名包 `work/out/Va11IOS-1.1.0-unsigned.ipa`（build 132）。

## 1. 游戏侧调用链（UTMT 反编译 + runner 反汇编确认）

标题 / 暂停菜单 → 设置：

- `gml_Object_mainsettings_button_Create_0`：按钮最终位置 `x = room_width/2 + 1.5 * sprite_width - 8`，
  `y = 278 - sprite_height/2`（房间 640×360）；
- `gml_Object_config_obj_Create_0`：面板 `x = room_width/2 = 320`、`y = room_height/2 - 33 = 147`；
- `gml_Object_vibration_config_Create_0`：HD 振动行 `x = config_obj.x = 320`、`y = config_obj.y + 65 = 212`；
- `gml_Object_vibration_config_Mouse_7`（鼠标左键释放）→ `Other_10`：
  `global.vibration_strength` 按 `0 → 0.5 → 1.0 → 0` 循环，`vibroindex` 同步 0/1/2，再触发 `user1`；
- `gml_Object_vibration_config_Other_11` → `local_vibranium.canvibrate = 1`；
- `gml_Object_local_vibranium_Step_0` →
  `gamepad_set_vibration(global.CURRENT_PAD_ID, global.vibration_strength, global.vibration_strength)`，
  `alarm[0] = room_speed/5`（≈ 0.2 s）后 `gamepad_set_vibration(..., 0, 0)`。

runner 侧（`main` 模块反汇编）：

- `gamepad_set_vibration` 实现（`main+0x1b73a0`）只把左右强度写进 GM 手柄对象（`+0x58` / `+0x5c`）；
- 每帧的手柄更新函数按当前 `NpadStyleTag` 调 `nn::hid::SendVibrationValue`：全键/掌机/双手柄各
  左、右各一次；停止时振幅为 0；
- 初始化时调 `IsVibrationPermitted`、`GetNpadStyleSet`、`GetVibrationDeviceHandles`、
  `InitializeVibrationDevice`、`GetVibrationDeviceInfo`。

**关键语义：一次震动 = 每帧重复发同一振幅，不是一次调用。** HLE 不能「收到非零就震」。

## 2. 宿主实现

`va11mobile/dm/host/hle_hid.c`（nn::hid 震动面）：

| 符号 | 行为 |
|---|---|
| `IsVibrationPermitted` | 返回 1（否则 runner 不初始化震动设备） |
| `GetVibrationDeviceHandles` | 按手柄变体返回 2 / 1 个**非零**句柄；句柄编码 `0x01000000 \| (npad_id << 8) \| index`，低 8 位 = 0 左 / 1 右（runner 只原样传回，编码对宿主不透明） |
| `InitializeVibrationDevice` | 成功（无设备可初始化） |
| `GetVibrationDeviceInfo` | 写 8 字节 `{type=1 线性马达, position=左/右}`，返回 0 |
| `SendVibrationValue` | 取 `VibrationValue{amp_low, freq_low, amp_high, freq_high}` 的 `max(amp_low, amp_high)`；距上一次非零值 **> 120 ms** 才算新脉冲，调一次 `front_haptic(amp)`；振幅 < 0.02 视作停止 |

`va11mobile/dm/host/front.h` 新增 `void front_haptic(float intensity)`：

- iOS（`va11mobile/iosapp/Sources/main.m`）：`UIImpactFeedbackGenerator`，
  重 / 中 / 轻档按振幅选，`impactOccurredWithIntensity: 0.30 + 0.70 * amp`；主线程执行；
- Mac（`front_mac.m`）：空实现（无触感硬件）。

## 3. 验证

### 3.1 模拟器（调用链）

用 App 自带的测试输入钩子复现（`DM_TEST_STEP`，坐标为画面归一化坐标）：

```
# 跳过开场 → 标题 → 点「设置」(0.67, 0.77) → 点「HD 振动」(0.5, 0.589)
DM_TEST_STEP="at:20000;click:0.5,0.5;wait:2200;…（共 16 次）;wait:5000;click:0.67,0.77;wait:4000;click:0.5,0.589;wait:5000"
```

`Documents/boot.txt` 关键行（一次点击，各一条）：

```
[dm] [hid-vib] GetVibrationDeviceHandles id=32 style=0x2 → 2 个（左/右）
[dm] [hid-vib] InitializeVibrationDevice 句柄=0x1002000
[dm] [hid-vib] 首次震动：句柄=0x1002000 振幅=1.00 低频=160 Hz 高频=320 Hz
[dm] [haptic] 前端震动：振幅 1.00 → 重 档，强度 1.00
```

截图：`work/out/vib_s6_rot.png`（设置页刚打开，HD 振动 = 软）、`work/out/vib_s7_rot.png`
（点击后 HD 振动高亮、值变「硬」）。`[haptic]` 只有一条 → 逐帧重复发值没有变成连震。

### 3.2 arm64 出包

```sh
cd va11mobile/iosapp && ./build.sh
# 结论: 0 项红（四段 __DM*W + __img、无 codesign 槽、ad-hoc 自签演练通过）
```

## 4. 已知边界 / 下一步

- **真机触感已确认**：用户实测设置页 HD 振动有震感；模拟器没有 Taptic Engine，只用于验证
  HLE 调用与前端调用是否发生；
- 原版语义下 `硬 → OFF` 那一次振幅为 0（游戏自己发 0），**不会震**，不是 bug；
- 当前是「一次脉冲一次 impact」，不是持续 0.2 s 的连续震动；若要更像 Switch HD 震动，可后续换
  CoreHaptics 连续事件（需在 iOS 工程加 CoreHaptics framework，并保留 UIImpactFeedbackGenerator 兜底）；
- 调酒流程的 `vibranium` 模式（adding/mixing/blending/agicing）走同一路径；脉冲间隔 < 120 ms 会被
  合并成一次触感，如手感不对再调阈值。
