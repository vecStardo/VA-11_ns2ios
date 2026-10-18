# AGENTS.md — VA-11 HALL-A iOS 移植工程约定

本文件对本仓库内工作的所有 Agent（DSH / Codex / Claude Code / LoopX 托管 Agent）**强制生效**。
新会话第一件事：读完本文件再动手。

## 提交纪律（强制）

1. **每一轮只要修改了文件，收尾必须 `git commit`。** 不允许把未提交的改动留在工作区后结束回合。
2. 一次逻辑批次一个提交：实现与其验证脚本 / 文档放同一个 commit；互不相关的改动不要混在一起。
3. 提交前跑最小验证（构建 / 冒烟 / 脚本自检），把结果写进提交信息。
4. 提交信息格式：

   ```
   <type>(<scope>): <一句话摘要>

   变更：<做了什么>
   验证：<跑过的命令与结果>
   风险/待办：<剩余风险或下一步>
   ```

   type 取 `feat` / `fix` / `test` / `docs` / `chore` / `refactor`；scope 取 `dm` / `iosapp` / `tools` / `verify` 等。
5. 提交后用 `git log --oneline -1` 回读确认，并把 commit hash 写进对应 LoopX Todo 的 evidence。
6. 确实无法提交（无改动 / 冲突无法安全解决）时，在回合结论里明确说明原因，不要静默跳过。

## 禁止提交的内容

- `.loopx/`、`.codex/` 下的本地状态与私有证据（已在 `.gitignore`，不要 `git add -f`）。
- 构建产物：`Gen/`、`work/out/`（默认出包目录已移到仓库外）、`*.dSYM`、`dm/host/dmhost_m3`。
- 工作目录约定：`work/` 与本仓库同级（`VA11_WORK` 可改），游戏文件/密钥/改写产物/调试 dump 都在那里；
  不要把游戏数据或密钥放进仓库根目录。
- 游戏本体资源 / 汉化补丁 / NSZ：`work/game/`、`Resources/dm/`、`d2r-mobile/`。
- 凭据、token、个人绝对路径、原始日志。

## 其它

- 不执行破坏性 git 操作（force push、`reset --hard` 覆盖他人改动、改写历史），除非用户明确要求。
- 每回合结束回报：改动文件、验证命令与结果、commit hash、剩余风险、下一步。
