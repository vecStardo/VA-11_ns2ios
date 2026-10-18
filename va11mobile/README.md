# VA-11 HALL-A · iOS 移植

把已购买的《VA-11 HALL-A》（Nintendo Switch 版，含中文补丁）跑在 iPhone / iPad 上，
交付**无签名、可由自签工具安装的 `.ipa`**。

本仓库**不包含任何游戏文件**：游戏程序与 `game.win` 需要你自己从正版游戏里准备（见下）。

```
d2r-mobile/                 参考项目（Diablo II Resurrected 的 iOS 移植思路来源）
va11mobile/
  dm/                       宿主（改编自 d2r-mobile 的 dm/）：装载器 / HLE 系统服务接管 / 图形层 / iOS 侧素材
    host/                   宿主核心（macOS 宿主 dmhost_m3 与 iOS 共用同一份源码）
    gfx/                    NVN → Metal 图形层（VA-11 路径不走它，见「与 d2r-mobile 的对照」）
    ios/                    d2r-mobile 的 iOS 工程素材（内嵌段生成工具 gen_embed.py 等）
    tools/                  程序改写器 patch_nso.py 与配套脚本
  iosapp/                   **VA-11 的 iOS 出包工程**（壳 + 宿主前端 + 无签名打包流水线）
    Sources/main.m           front.h 的 iOS 实现：窗口 / EAGL 出图 / 触摸 / 虚拟按键 / 生命周期
    build.sh                 三步出包：内嵌映像 → xcodebuild（无签名）→ Payload → .ipa → 结构校验
    smoke_sim.sh             模拟器冒烟：装机 → 塞 game.win → 启动 → 等主循环 → 截图
    gen_build_ios.py         从 dm/host/Makefile 展开 iOS 的源文件/头路径/宏/框架
    patch_product_ios.py     出包期补丁（iOS 不能改代码页）
    gen_icon.py              App 图标 / 启动画面素材
    README.md                iOS 壳与前端的技术细节
  docs_ref/                  d2r-mobile 的文档备份（对外部参考，不是 VA-11 专属说明）
```

## 怎么工作（架构）

游戏本体是 Switch 的 GameMaker 运行时（YYC）加一份 `game.win` 数据包，和 iPhone 同为 arm64。

1. **改写程序**（`dm/tools/patch_nso.py`）：把 main / sdk / subsdk0 / subsdk1 里在苹果内核下不能原样执行的少量指令改写掉
   （`x18` / `tpidr*` 寄存器、`svc` 系统调用、系统计数器等），产出 `*.patched.bin` 与装载表/门表。
2. **宿主装载与 HLE**（`dm/host/`）：`loader.c` 扮演 Horizon 装载器把映像映射回来并做跨模块重定位；
   `hle*.c` 在 SDK 接口层接管文件系统、输入、音频、时间、账号、错误对话框等服务，游戏像在真机上一样跑。
3. **图形**：GM runner 用 EGL + OpenGL ES 画图。宿主把 `egl*` 接到平台 GL：
   - macOS 宿主（`dmhost_m3`）：NSOpenGLContext（桌面兼容剖面，着色器源码微调）；
   - iOS 壳：**EAGL / GLES 2.0**（`dm/host/hle_egl_ios.m`），GM 的 GLSL ES 1.00 着色器原样可编。
   `glBindFramebuffer(0)` 被换成宿主 FBO，`eglSwapBuffers` 用 `presentRenderbuffer:` 上屏。
4. **iOS 壳**（`va11mobile/iosapp/`）：窗口 + EAGL 视图（逻辑 1280x720，等比缩放到屏幕），
   把宿主日志写到 `Documents/boot.txt`，在后台线程跑 `dm_main`；触摸整组推给宿主（`dm_touch_set`），
   并额外提供「触点→鼠标面」与右下角 A/B/＋、左下角十字键，覆盖点选与手柄两种交互。
5. **无签名出包**：改写后的模块映像以内嵌汇编（`__TEXT,__dm<名>x0` / `__DM<名>W,__img` / `__TEXT,__dm<名>x1`）
   编进可执行文件，`CODE_SIGNING_ALLOWED=NO` 构建 arm64，打包成 `Payload/Va11IOS.app` 的 `.ipa`，
   结构与自签可行性由 `build.sh` 的校验段逐项核对。

## 准备游戏文件（必须自备）

1. 购买并解包 Switch 版《VA-11 HALL-A》（本仓库用 1.0.0 汉化补丁的 `game.win` 验证）。
2. 用 `dm/tools/patch_nso.py` 改写 ExeFS 里的 `main`、`sdk`、`subsdk0`、`subsdk1`，产物目录（缺省 `~/va11-work/patched`）
   需要 `*.patched.bin` + `*.fixups.tsv` + `*.gates.tsv`。
3. `game.win`（约 520 MB）与 `preselected_user`（内容 `False`）在装机后放进 App 的 `Documents/save/`。

## 构建与出包

前置：macOS + Xcode 26、`xcodegen`、Python 3（`Pillow`）、上面的改写产物。

```sh
cd va11mobile/iosapp
DM_PATCHED=~/va11-work/patched ./build.sh      # → out/Va11IOS-unsigned.ipa + out/verify.txt（结构校验）
./smoke_sim.sh                                  # 模拟器冒烟：装 GAME-OK 判定 + 截图
```

真机安装：用 AltStore / Sideloadly 等自签工具对 `out/Va11IOS-unsigned.ipa` 补签后安装；
首次启动后用「文件」App 把 `game.win`、`preselected_user` 放进「VA-11 HALL-A → save」。

## 与 d2r-mobile 的对照

| 维度 | d2r-mobile（D2R） | 本移植（VA-11） |
|---|---|---|
| 游戏引擎 | 原生 Switch 程序（NVN 图形） | GameMaker YYC 运行时（EGL + GLES） |
| 图形后端 | NVN 调用录制 → Metal 重放（`gfx/nvn`） | EGL → 原生 GL：macOS 用 NSOpenGL，iOS 用 EAGL/GLES |
| 程序改写 | `x18`/`tpidr`/`svc`/`cntpct` 改写 + 剪口 + 观测门 | 同思路；按 VA-11 构建号登记剪口 |
| 内嵌与装载 | iOS 不允许运行期写代码页 → 内嵌段 + `vm_remap` | 完全相同（复用 `dm/ios/tools/gen_embed.py`） |
| 资源数据 | RomFS（9 GB，苹果托管资源包） | 单文件 `game.win`（约 520 MB，放 Documents） |
| 输入面 | 触屏覆盖层 + 手柄（`ios/Sources` 的触控套件） | 触屏→鼠标面 + A/B/＋ 与十字键虚拟手柄 |
| 出包 | 签名 / TestFlight / 商店 | 无签名 `.ipa` + 自签工具安装 |
| 验证 | 画面闸门 / 回放 / 浸泡 / 真机 | 模拟器冒烟（主循环/截图）+ HID 回执 + 结构校验 |

## 已知限制

- **真机未验证**：目前只在 iOS 26.3 模拟器上跑通主循环、开场、标题与 SAVE/LOAD 界面；
  无签名 `.ipa` 已产出并通过结构校验，真机需自签后验证。
- 触屏 UI 还不完整：菜单导航与点选可用，但「点按推进对白」「调酒交互」的完整走查尚未完成。
- 图形走 GLES（runner 的原生路径）。若未来 iOS 彻底移除 OpenGL ES，需要把 GLES 调用翻成 Metal。
- 日志里有 4 条 d2r 遗留红字（OBS_C2S / OBS_TICK / OBS_TARGET_RANK 观测门、`main+0x20cefa8` 落盘节流原值核对），
  与 VA-11 无关，属宿主历史检查，后续应改为 `DM_FOREIGN_GAME` 下默认关闭。
- 模拟器 Debug 下游戏节拍约 28 Hz（触摸读采样估算）；真机 Release 待测。

## 验证记录（当前证据）

- `va11mobile/iosapp/out/boot_sim.txt`：模拟器冒烟日志，含 `Entering main loop`。
- `va11mobile/iosapp/out/evidence_title.png`：iOS 模拟器上的标题画面。
- `va11mobile/iosapp/out/evidence_ingame_saveload.png`：游戏内 SAVE/LOAD 界面（虚拟键驱动）。
- `va11mobile/iosapp/out/evidence_touch_ui_menu.png`：虚拟十字键与标题菜单同屏。
- `va11mobile/iosapp/out/evidence_opening_dialogue.png` / `evidence_opening_dialogue2.png`：iOS 模拟器上触屏点按进入
  「新游戏 → 开场旁白 → 下一段对话」（点按推进对白已验证；开场文本为日文，汉化语言待确认）。
- `va11mobile/iosapp/out/cn_p1_rot.png` / `evidence_zh_dialogue.png`：中文默认生效（补丁中文在英文槽，前端默认 `DM_LANG=en-US`）。

- `va11mobile/iosapp/out/Va11IOS-unsigned.ipa`（2026-10-18 11:1x 重新打包，17,019,361 B，sha256 前 24 位 `f3f19b2c192b6c8f66748e67`）：含「默认中文（DM_LANG=en-US）」「点按补 A」「切后台不崩」「帧同步点击队列 + 单步注入钩子」「KeyboardState 0x30 / MouseState 结构修正」「**按真机语义不再伪造鼠标（输入修复）**」；结构校验 0 项红。
- `va11mobile/iosapp/out/verify.txt`：无签名 ipa 结构校验（0 项红）。

## 合法使用声明

- **必须拥有正版游戏**。本仓库不含任何游戏程序、数据或美术资源，也不提供下载地址。
- 本项目仅用于在自己拥有的设备上运行自己购买的游戏（个人备份/移植研究）；请勿分发由游戏文件生成的内容。
- 《VA-11 HALL-A》及其素材、商标归 Sukeban Games / Ysbryd Games 等权利人所有；本项目与权利人无关。
- 移植核心与思路参考 d2r-mobile（Diablo II Resurrected 的社区 iOS 移植）；其中的社区离线修复规则来源见
  `docs_ref/DERIVED.zh-CN.md`。

---

# VA-11 HALL-A · iOS port

Runs an owned Nintendo Switch copy of VA-11 HALL-A on iPhone/iPad and ships an **unsigned `.ipa`** that can be installed
with a self-signing tool. The repository contains no game files: prepare the rewritten program modules and `game.win`
from your own copy. The host core is shared with the macOS host `dmhost_m3`; on iOS the EGL front end is hooked to
EAGL/GLES 2.0 (the GM runner's native path), the module images are embedded as signed code sections, and
`build.sh` produces and structurally verifies the unsigned package. Compared with d2r-mobile the approach is the same
(rewriter, HLE host, embedded images, unsigned pipeline) but the graphics route is EGL→GL instead of NVN→Metal and the
asset is a single `game.win` instead of RomFS. Known limits: verified on the iOS 26.3 simulator only; the touch UI still
needs complete dialogue/mixing walkthroughs; GLES is used because it is the runner's native API. Usage requires an owned
copy of the game; nothing derived from game files may be redistributed.
