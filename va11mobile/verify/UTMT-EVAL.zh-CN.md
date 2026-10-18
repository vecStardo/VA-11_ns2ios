# UndertaleModTool（UTMT）解析 game.win —— 实测：**能，而且能反编译全部 GML**

> 结论：能。UTMT CLI 0.9.2（macOS 自包含版）**直接打开了这份 520 MB 的 `FORM/GEN8` 容器**，
> 读出全部资源表，并**把 3518 个代码条目反编译成可读 GML**（15 MB 源码，见 `out/utmt/gml_all/CodeEntries/`，该目录在 `.gitignore` 内）。
> 更重要的两个发现：
> 1. 这份数据包 **不是 YYC**（`Is YYC - False`，字节码版本 17）——GML 逻辑就在 game.win 里，可以反编译；
> 2. `textbox_loadbox` 的台词来自**外部的 `chn/eng/jp/*.ini` 文件**（`buffer_load_async`），不在 STRG 里；
>    本项目只放了 game.win、没放这批 `.ini`——这是「变量未设置」崩溃目前最可信的根因（见下）。

## 实测环境

- macOS 15.7.3（arm64），UTMT **0.9.2.0**，资产 `UTMT_CLI_v0.9.2.0-macOS.zip`（58 MB，自包含 .NET，无需装 dotnet）
- 目标：汉化补丁 `romfs/game.win`（520,720,771 B）；对照：未汉化原版 `~/va11-work/orig/game.win`
- 安装位置 `out/utmt/`（gitignored）：`app/UndertaleModCli`；工作目录 `out/utmt/`

## 加载结果（`UndertaleModCli info`）

```
Is YYC - False
Bytecode version - 17
Configuration name - "default"
121 Sounds, 939 Sprites, 0 Backgrounds
0 Paths, 498 Scripts, 2 Shaders
44 Fonts, 0 Timelines, 740 Game Objects
47 Rooms, 1 Extensions, 2500 Texture Page Items
3518 Code Entries, 7345 Variables, 697 Functions
3517 Code locals, 15185 Strings, 69 Embedded Textures
120 Embedded Audio
```

耗时 0.88 s，峰值 RSS 约 492 MB。**加载无任何警告/失败**，读表完整。

## 反编译

```sh
cd out/utmt/app
./UndertaleModCli dump <game.win> -c UMT_DUMP_ALL -o ../gml_all      # 3518 个 .gml，≈15 MB
./UndertaleModCli dump <game.win> -s -o ../dumpstr                    # strings.txt
```

反编译出的 `gml_Script_textbox_loadbox`、`gml_Script_day0control`、`gml_Object_obj_textbox_*`
与日志里追的崩溃点一一对应——**以后定位游戏逻辑不需要再手工反汇编 main**。

## 关键发现 1：不是 YYC，是 VM 字节码

- `info` 明确 `Is YYC - False` + `Bytecode version - 17`（GMS 1.4 VM），并且在 dump 时**没有**打印
  「The game was made with YYC … no code to dump」——它真的反编译出了语句。
- 这与 `README.md`「GameMaker YYC 运行时」的说法冲突。含中文的 3518 个代码条目就是证据；
  建议把 README 与研究结论里的「YYC 原生码」改成「VM 字节码（v17）+ Switch 原生 runner」。
- 影响：以前「GML 编译进 main、只能反汇编」的路线（`main+0x1809c` 观测门等）**不再必要**；
  但运行期崩溃仍可用观测门定位到具体 GML 行。

## 关键发现 2：台词来自外部 `.ini`，不在 STRG —— 「变量未设置」根因

反编译出的 `gml_Script_textbox_loadbox`（原版与汉化版**逐字相同**）：

```gml
if (global.consoles_flag) {
    var curtext = ds_map_find_value(global.dialog_files_texts, temp_fname);
    ini_open_from_string(curtext);
    if (temp_pointer != 0) {
        var st_pointer = string(temp_pointer);
        var count = ini_read_real(st_pointer, "count", 0);
        for (i = 1; i < (count + 1); i += 1) {
            var line = ini_read_string(st_pointer, "l_" + string(i), "");
            if (string_count("INI_QUOTS", line) > 0) line = string_replace_all(line, "INI_QUOTS", "\"");
            ds_queue_enqueue(text_queue, line);
        }
    }
    ini_close();
}
...
total_boxes = ds_queue_size(text_queue) - 1;
for (var i = 0; i < (total_boxes + 1); i++) input_text[i] = ds_queue_dequeue(text_queue);
...
textbox_cmd_load(input_text[current_text]);        // ← current_text = 0；input_text[0] 没赋值就是「变量未设置」
```

而 `gml_Object_async_init_*` 说明 `dialog_files_texts` 是怎么来的：

```gml
// Create_0：os_switch / os_ps4 → 扩展名 .ini，路径 "chn/script1.ini"…（非主机才是 "scripts/eng/*.txt"）
global.testscript = lang_val + "/testroom" + txt_ext; …
// Step_0：逐个 buffer_load_async（异步读文件）
buffer_load_async(loadbuff, ds_list_find_value(global.dialog_files, cur_ind), 0, -1);
// Other_72（异步完成）：读出 buffer_string 塞回 map
ds_map_set(global.dialog_files_texts, ds_list_find_value(global.dialog_files, cur_ind), curtext);
```

**推论链**：文件缺失/异步加载没发生 → `dialog_files_texts` 为空 → `textbox_loadbox` 拿到空文本
→ 队列空（`total_boxes = -1`）→ `input_text[0]` 从未赋值 → `textbox_cmd_load(input_text[0])`
抛 **「变量未设置」**。与日志里「任何 textbox 创建都触发」一致。

### 证据：这批 `.ini` 确实在游戏 NCA 里（只是没被取出）

对 `~/va11-work/program.nca` 做字节统计（python `bytes.count`）：

| 模式 | 出现次数 | 说明 |
|---|---|---|
| `INI_QUOTS` | **1214** | 台词行里的引号占位符（game.win 自身只有 **1** 个，即 GML 常量） |
| `.ini` | 94 | 约 84–94 个台词文件 |
| `eng/` / `chn/` / `jp/` | 28 / 28 / 34 | 三套语言目录 |
| `scripts/eng/…txt` | 28 | GML 里 PC 分支的硬编码路径（主机分支不用） |

偏移 ~0x1F6D…（`528,679,461`）处能直接看到中文 ini 内容：
`l_21 = "[XS:jilltalk,1][C:13]Jill：[C:C]INI_QUOTS世上的最后一场雨。…"`，
偏移 ~0x20C…（`549,347,706`）处是日文。**台词在 romfs 的 `chn/*.ini` 里，不在 game.win 的 STRG。**
这也更正了 `INPUT-DIAG` 里「中文台词就在 STRG 里」的结论（STRG 里 1497 条 CJK 是 UI/道具等文案）。

## 建议的下一步

1. 从 `program.nca` 的 romfs 里取出 `eng/ chn/ jp/*.ini`（以及 romfs 根的 game.win），放到宿主
   `rom` 挂载点：`hle_fs.c` 已有 `rom → $DM_ROMFS`（`DM_ROMFS_OVERLAY` 可选），但
   `va11mobile/iosapp/Sources/main.m` **目前没有 setenv("DM_ROMFS", …)**；
   若 iOS 端不便放多文件，可先把 `.ini` 打进 App 资源目录再指过去，或扩展 HLE 让 `buffer_load_async`
   命中内嵌表。
2. 用 `DM_FSLOG` 确认游戏是否去读了 `chn/script1.ini`；
3. 再看 `textbox_loadbox` 是否不再抛错——若仍报错，GML 源码已在手上，可直接定位到变量。

## 复现

```sh
mkdir -p out/utmt && cd out/utmt
curl -L -o utmt.zip https://github.com/UnderminersTeam/UndertaleModTool/releases/download/0.9.2.0/UTMT_CLI_v0.9.2.0-macOS.zip
unzip -q utmt.zip -d app
cd app && ./UndertaleModCli info "<game.win>"
./UndertaleModCli dump "<game.win>" -c UMT_DUMP_ALL -o ../gml_all
```

> 注：`out/` 与 `out/utmt/` 均不入库；`gml_all` 是 15 MB 生成物，需要时按上面命令重跑。
> 本文件只记录结论与证据，未改动源码。
