# 台词加载补丁（day0 黑屏修复）

## 为什么需要

Switch 版把台词放在 **romfs** 里（`romfs/scripts/eng/*.ini`），由 `async_init` 的 Step 事件用
`buffer_load_async` 逐个读进 `global.dialog_files_texts`。本移植的宿主没有实现 GameMaker 这条
异步文件链（它的 file/buffer 接口不经过 nn::fs 钩子），所以那张 map 永远是空的：
`textbox_loadbox` 查不到文本 → `input_text` 从不赋值 → 点新游戏后黑屏/报错。

## 做法（已实测）

1. 用 `apply_patch.sh` 把 `gml_Object_async_init_Step_0` 换成「同步从 `host:/<文件名>` 读」的版本；
2. 把 `romfs/scripts/eng/` 整个目录放进 App 的存档目录 `Documents/save/eng/`
   （`host:/eng/...` 正好对应这个位置，而端口对 `host:` 的读是好的）。

## 验证

- 日志 28 个台词文件全部加载；
- 点「新游戏」进入酒吧，底部对话框显示 `Anna: Pssst.`（截图 `out/day0_fixed.png`）。

## 现成产物

iCloud：`Va11IOS-patched-data/game_patched_EN.win`（已打好补丁的英文数据）
+ `eng.zip`（解压到 `Documents/save/` 下，形成 `Documents/save/eng/`）。

## 复现命令

```sh
tools/romfs_patch/apply_patch.sh <原始 game.win> <输出 game_patched.win>
```
