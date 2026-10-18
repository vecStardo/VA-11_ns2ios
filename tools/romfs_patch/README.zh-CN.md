# 台词加载补丁（day0 黑屏修复的关键）

背景：Switch 版把台词放在 romfs 的 `scripts/eng/*.ini`，由 `async_init` 的 Step 事件用
`buffer_load_async` 逐文件加载进 `global.dialog_files_texts`。本移植的宿主没有实现这条异步文件链
（GameMaker 的 buffer/file 接口在端口里不落到 nn::fs 钩子上），所以那张 map 永远是空的，
`textbox_loadbox` 拿不到 INI 文本 → `input_text` 从不赋值 → day0 黑屏。

做法（已实测有效）：
1. 把 `romfs/scripts/eng/` 整个目录放进 App 存档目录（`Documents/save/eng/`，即 `host:/eng/...`）；
2. 用 UndertaleModTool 把 `gml_Object_async_init_Step_0` 替换成
   `async_init_step_host.gml`（同步从 `host:/<文件名>` 读取并 `ds_map_set` 进 map）。

结果：模拟器里 **28 个台词文件全部加载**（日志 28 行 LOADED），点新游戏后进入酒吧场景，
底部出现 `Anna: Pssst.` 对话框——day0 黑屏问题解决。

复现补丁：
```sh
# 需要 out/utmt/app（UTMT CLI）
UndertaleModCli replace game.win \
  -c "gml_Object_async_init_Step_0=tools/romfs_patch/async_init_step_host.gml" -o game_patched.win
```
