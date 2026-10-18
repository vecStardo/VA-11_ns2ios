# REA（rea-cn / rea-agents）能否解析 game.win —— 评估结论

> 结论先行：**不能**。REA 是「原生二进制（Hopper / Ghidra / IDA）+ JS / .NET / Android / APK 等」
> 的逆向前端（MCP 服务 + CLI），**没有 GameMaker `FORM/GEN8` 容器的 loader**。
> `game.win` 在 REA 的每个入口都被判 `unsupported binary format`。

## 测试环境

- macOS 15.7.3 / Node v26.8.2 / npm 11.19.1
- `rea-agents` **6.7.0**（`npm i rea-agents@6.7.0`，装在 `out/rea-probe/`，该目录在 `.gitignore` 内，不入库）
- 目标：汉化补丁 `romfs/game.win`，`520,720,771` 字节，头 `FORM <len> GEN8`（`file` 报 **IFF data**）
- 对照目标：`Info.plist`（REA 认识的格式）、`~/va11-work/exefs/main`（Switch NSO）

## 实测命令与结果（全部 exit=1）

| 命令 | 结果 |
|---|---|
| `rea inspect-artifact <game.win> --json` | `target_unavailable` / `unsupported_target`：`Cannot open artifact: unsupported binary format.`，`constraint: file_format_rejected` |
| `rea inspect <game.win> --json` | 同上 |
| `rea analyze <game.win> --json` | 同上 |
| `rea extract-artifact <game.win> --json` | 同上 |
| `rea analyze <main.nso> --json` | 同上（Switch NSO0 也不认识） |
| `rea inspect-artifact <Info.plist> --json` | **正常**产出 evidence：`format: "plist"` + sha256，说明不是环境/安装问题 |
| `rea doctor --json` | hopper / ghidra / ida-registration / jadx / kuna **全部 missing_analysis_engine**；本机未装任何分析引擎 |

补充证据：

1. **包内没有 GameMaker 支持**：`grep -r 'GEN8\|GameMaker' node_modules/rea-agents` → 0 命中；
   唯一 `data.win` 命中是 `data.window`（误报）。
2. `rea inspect-binary-layout` → `capability_unavailable`（pwntools 通道只支持 Linux x64）。
3. “任意二进制”只有 Ghidra **raw-binary** 通道（`--target-format raw-binary --architecture arm64 --entry-point 0x…`），
   它把整个文件当**指令**映射，不做容器解析；对 `game.win` 这种数据文件只会把数据误读成指令，没有意义。
4. Hopper / IDA 明确拒绝 raw-binary 目标；Ghidra 需自行安装（`GHIDRA_INSTALL_DIR`）。

## 为什么是这个结果

`game.win` 是 GameMaker（GMS 1.4 / `GEN8`）的**资源数据容器**，不是可执行文件：
`OPTN LANG EXTN SOND AGRP SPRT BGND PATH SCPT GLOB SHDR FONT TMLN OBJT ROOM DAFL EMBI TPAG TGIN
CODE VARI FUNC STRG TXTR AUDO`（本项目已按 chunk 表走通，见 `INPUT-DIAG.zh-CN.md`）。
它里面没有 PE/ELF/Mach-O/NSO 任一可识别头，也没有 GML 以外的“标准”可执行代码供反汇编器消费。

想读这些表，正确工具仍是：

- 本仓库现有的走表脚本（STRG/VARI/CODE 已打通，`input_text` = STRG #2217、VARI `first_addr=0xa33984`）；
- 或 **UndertaleModTool**（支持 GEN8 容器的 STRG/VARI/TXTR/AUDO 等表；
  YYC 构建的代码部分仍需另想办法）。

## REA 在本项目里真正可能有用的位置（待验证，不是本轮结论）

REA 的价值在**原生 arm64**，不在 game.win：

- 本项目现在靠手工反汇编 `main`（如 `main+0x1809c` 的数组/变量检查 helper）。
  把 NSO 转成 ELF 后装 Ghidra（REA 的 ghidra provider，需 Ghidra 12.1.x + JDK），
  就能用 `rea analyze / decompile / xrefs / trace` 做交叉引用与伪代码，替代手翻反汇编。
- 代价：Ghidra 体积大、首次导入慢；NSO0 需先转 ELF（REA 不认 NSO 头，已实测）。

## 复现

```sh
mkdir -p out/rea-probe && cd out/rea-probe
export npm_config_cache="$PWD/.npm-cache"
npm i --no-audit --no-fund rea-agents@6.7.0
./node_modules/.bin/rea doctor --json
./node_modules/.bin/rea inspect-artifact \
  "/Users/stardo/Project/VA-11_ios/赛博朋克酒保行动 Cyberpunk Bartender Action/1.0.0汉化补丁/010086500D3C8000/romfs/game.win" --json
```

> 注：本文件只记录评估结论；`game.win` 本身与 `out/rea-probe/` 均不入库。
