# iosapp/ — VA-11 HALL-A 的 iOS 外壳与宿主前端

总体说明（架构、装机/自签指引、与 d2r-mobile 的对照、合法使用声明）见 [../README.md](../README.md)。

English follows the Chinese sections.

这个目录把 `va11mobile/dm` 的宿主（装载器 + 系统服务接管 + 图形层）接到 iOS 上，出无签名可自签安装的 `.ipa`。
宿主核心与 Mac 命令行宿主 `dmhost_m3` 是同一份源码：`build.sh` 从 `dm/host/Makefile` 展开编译命令，
取出源文件 / 头路径 / 宏 / 框架（`gen_build_ios.py`），iOS 上只换掉两个平台专用文件：

| Mac | iOS | 作用 |
|---|---|---|
| `dm/host/front_mac.m` | `Sources/main.m` | `front.h` 的实现：窗口、出图视图、触摸、软键盘、生命周期、存档失败提示 |
| `dm/host/hle_egl.m` | `dm/host/hle_egl_ios.m` | GM runner 的 EGL/GL → 平台 GL：Mac 是 NSOpenGLView（桌面兼容剖面），iOS 是 EAGL/GLES 2.0 |

## 怎么工作

1. `Sources/main.m` 的 `main()` 先备好环境（`DM_SAVE`/`DM_TEMP` 指向 Documents，工作目录切到 Documents，
   日志重定向到 `Documents/boot.txt`，产品目录 = 包内 `Resources/dm` 的装载表/门表），再进 `UIApplicationMain`。
2. App 起来后建窗口与 EAGL 视图（逻辑尺寸 1280x720 = GM runner 的固定视口，`contentsScale=1`，再用等比 transform
   缩到屏幕上），把视图交给 GL 垫片，**在主线程预建 EAGLContext 与 FBO**（见下），然后在 64 MiB 栈的后台线程调
   `dm_main`（`dm/host/main.c` 以 `-Dmain=dm_main` 编入）。
3. `dm_main` → 宿主装载四个改写后的模块映像（内嵌在可执行文件的 `__dm<名>x0` / `__DM<名>W` / `__dm<名>x1` 段，
   `dm/ios/tools/gen_embed.py` 生成；iOS 不允许运行期写代码页，装载器用 `vm_remap` 按原相对位置映射回来）→
   `nnMain` → GM runner 用 EGL + GLES 画图、通过宿主 HLE 读 `save:/game.win`、出声、读触屏。
4. 图形：`hle_egl_ios.m` 把 `egl*` 全接到 EAGL；`gl*` 直连系统 GLES（GM 的着色器本来就是 GLSL ES 1.00，
   不需要 Mac 那套「降到桌面兼容剖面」的源码微调）。`glBindFramebuffer(0)` 被换成宿主的 FBO（EAGL 没有窗口默认帧缓冲），
   `eglSwapBuffers` 用 `presentRenderbuffer:` 上屏。
5. 触摸：视图的多点触摸整组推给 `dm_touch_set`（归一化坐标），宿主换算成游戏面板坐标后由 `nn::hid` 读走。
6. 音频：`dm/host/hle_audio.c` 的 iOS 分支走 RemoteIO，缺省真出声。
7. 存档/文件系统：`dm/host/hle_fs.c` 把 `save:` 挂到 `Documents/save`（事务式提交用 clonefile + rename swap）。

## 两个关键坑（已固化在代码里）

- **EAGL 的上下文与 FBO 必须在主线程建**：先在后台（客体）线程建 drawable 时，GL 里画得出画面、`glReadPixels`
  也有内容，但 `presentRenderbuffer` 上不了屏（iOS 26 模拟器实测全黑）。现在由 `hle_egl_prepare_on_main()`
  在主线程预建，客体线程只借用上下文渲染 + 上屏。
- **画布尺寸必须等于游戏视口**：GM runner 固定 1280x720（`nn::oe` 默认显示分辨率，Mac 上 `glprobe` 实测 vp=1280x720）。
  画布用 1600x900 时画面只占左下角。

另外两条在 Mac 宿主上是「装载期改代码页」的补丁（`main+0xd476d8`、`sdk+0xc0764` 的 udf 空洞补 RET），
iOS 上不能这么干：出包时由 `patch_product_ios.py` 落到内嵌用的产物副本上（幂等，原字节不是 udf/RET 就报错）。

## 构建与验证

```
DM_PATCHED=work//patched ./build.sh     # 无签名 .ipa → out/Va11IOS-unsigned.ipa + out/verify.txt（结构自检）
./smoke_sim.sh                                # 模拟器冒烟：装机 → 塞 game.win → 启动 → 等主循环 → 截图，判 GAME-OK/RED
```

- `build.sh` 需要 `dm/ios/tools/gen_embed.py`（与 d2r-mobile 同一份）和改写产物目录（`DM_PATCHED`，缺省 `work//patched`，
  含 `main/sdk/subsdk0/subsdk1` 的 `.patched.bin` 与 `.fixups.tsv`/`.gates.tsv`）。
- `smoke_sim.sh` 的 `game.win` 缺省从本仓 `赛博朋克酒保行动…/1.0.0汉化补丁/010086500D3C8000/romfs/game.win` 取，
  可用 `DM_GAME_WIN=...` 覆盖；模拟器容器里用 APFS 克隆放置，不额外占空间。

## 游戏数据（真机）

App 开了 `UIFileSharingEnabled`：用「文件」App 把 `game.win`（520 MB）和 `preselected_user`（内容 `False`）
放进 App 的「在我的 iPhone 上 → VA-11 HALL-A → save」目录即可（即 `Documents/save`）。
首次启动会自己建 `Documents/save` 与 `Documents/temp`。日志在 `Documents/boot.txt`（行即刷，含宿主全部装载/服务日志）。

## 输入（触屏优先）

- 点画面 = 鼠标点选（触点经 `hle_touch.c` 的鼠标面送进 `nn::hid::GetMouseStates`）；短点按还会在抬起后
  150 ms 内部补一次 120 ms 的 A，用来走通「Aを押してスタート」这类只认 A 的提示。
- 虚拟手柄键（A/B/＋、十字键）不是产品功能，只在 `DM_VIRTUAL_PAD=1` 时显示，供诊断/对照。

## 已知限制与下一步

- **真机未验证**：目前只在 iOS 26.3 模拟器上跑到主循环、开场与标题画面；无签名 `.ipa` 已出（真机需自签工具补签）。
- 触摸 UI 覆盖层（虚拟按键 / 点按适配）还没做，属于「iOS 壳 App」todo；当前是原版触屏语义（点哪算哪）。
- 模拟器 Debug 下游戏节拍约 28 Hz（触摸读采样计数估的）；真机 Release 与性能档另测。
- 日志里有 4 条 d2r 遗留红字（OBS_C2S / OBS_TICK / OBS_TARGET_RANK 观测门、`main+0x20cefa8` 落盘节流原值核对），
  是 d2r 专属功能的检查，对 VA-11 无影响；应改成 `DM_FOREIGN_GAME` 下默认关闭，免得误读成故障。
- 图形走 GLES（GM runner 的原生路径）。若将来 iOS 彻底移除 OpenGL ES，需要把 GLES 调用翻成 Metal
  （d2r-mobile 的 `gfx/nvn` 是 NVN→Metal，不适用于这里）。

---

# iosapp/ — VA-11 HALL-A iOS shell and host front end

This directory hooks the host from `va11mobile/dm` (loader + service take-over + graphics layer) up to iOS and packages
an unsigned, self-signable `.ipa`. The host core is the same source as the Mac command-line host `dmhost_m3`:
`build.sh` expands `dm/host/Makefile` and takes the source files / header paths / macros / frameworks from it
(`gen_build_ios.py`), replacing only the two platform files: `front_mac.m` → `Sources/main.m` (the `front.h`
implementation) and `hle_egl.m` → `dm/host/hle_egl_ios.m` (EGL/GL → EAGL/GLES 2.0 instead of NSOpenGLView).

Flow: `main()` prepares the environment and log, then UIKit builds the window and the 1280x720 EAGL view; the EAGL
context and FBO are created **on the main thread** (`hle_egl_prepare_on_main`) because a drawable created on the guest
thread renders but never reaches the screen on iOS 26; `dm_main` then runs on a 64 MiB-stack background thread, loads the
four embedded module images, and the GM runner draws with GLES, reads `save:/game.win` through the host HLE, plays audio
through RemoteIO, and reads touches pushed by the view via `dm_touch_set`. `glBindFramebuffer(0)` is remapped to the host
FBO and `eglSwapBuffers` presents it.

Build and check: `DM_PATCHED=work//patched ./build.sh` (unsigned `.ipa` plus a structural report), then
`./smoke_sim.sh` (installs in the simulator, stages `game.win` with an APFS clone, waits for the main loop, screenshots,
verdict GAME-OK/RED). On a device, put `game.win` and `preselected_user` into the App's `save` folder through the Files app.

Known limits: verified on the iOS 26.3 simulator only (unsigned ipa produced, device install needs a self-sign tool);
no touch UI overlay yet (raw original touch semantics); ~28 Hz game tick in a Debug simulator; four d2r-specific red log
lines should be gated behind `DM_FOREIGN_GAME`. Graphics use GLES because that is the GM runner's native path; a Metal
translation would only be needed if iOS drops OpenGL ES entirely.
