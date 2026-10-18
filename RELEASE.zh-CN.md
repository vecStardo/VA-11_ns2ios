# 发布说明 / 不要随仓库分发的东西

本仓库（<https://github.com/vecStardo/VA-11_ns2ios>）是 **public** 的，里面只有：
驱动移植的源码、HLE/宿主、iOS 出包工程、工具脚本、文档与 App 图标。

## 仓库里没有、也永远不会有

| 内容 | 说明 |
|---|---|
| `game.win` | **完整游戏数据包**（GML 字节码 + 全部贴图 + 音频 + 文本，约 520 MB） |
| `.nsp / .nsz / .xci / .nca / .tik` | Switch 游戏本体 / 容器 / 票 |
| `prod.keys` / `title.keys` / `*.keys` | Switch 密钥 |
| romfs `scripts/<lang>/*.ini` | 游戏台词文本（默认构建会从**用户自己的** romfs 打入 IPA，属游戏内容） |

已用 `git log --all --diff-filter=A` 审计过全历史：以上任何文件都从未进入过本仓库。

## 哪些交付物只能私下给自己设备用

- `game_patched_EN.win` / `game_patched_CN.win`（**你自己游戏的修改副本**）；
- 内置台词 `.ini` 的 IPA（含游戏文本）；
- 导出的 `eng/` / `chn/` 台词目录。

这些**不要**作为 GitHub Release 附件、Issue 附件或公开链接分发。
需要「不含游戏内容」的 IPA 时用：

```sh
cd va11mobile/iosapp
DM_TEXTS_ROMFS=/nonexistent DM_PATCHED=work//patched ./build.sh
```

（产物约 16 MB，只有宿主代码；台词由使用者自己放进 `Documents/save/`。）

## 合法使用

你必须在自己的设备上运行**自己拥有的**游戏副本。本仓库不提供、也不帮助获取任何游戏文件或密钥。
