# windows-popup-flash

> 诊断并根治 Windows「每隔一会儿弹一个控制台黑框 / 打字被抢焦点」的排查技能（DeepSeek Harness Skill）。
> A DSH skill for hunting down and permanently fixing Windows console-window popups (cmd / powershell / python / tasklist ... flashes that steal focus).

---

## 症状长什么样

- 隔几分钟弹一个黑框，一闪而过；或者**黑框留在屏幕上几十秒到几分钟**，盖住别的窗口。
- 正在打字时焦点被抢走，光标跑掉。
- 常见于：后台脚本、计划任务、watchdog、agent（DSH / Codex / WorkBuddy…）调用 `ssh`/`scp`/`tasklist`/`python` 的时刻。
- 最难查的一类：**白天没规律，改完一处还有一处**——因为同一台机器上往往同时存在 3~5 个独立元凶。

## 它怎么工作

```
hunt（抓现形） → 定位 spawn 链（谁拉起来的） → 修最顶端的 spawn 点 → 重启该进程 → 复测验收
```

技能里带两个可直接跑的脚本：

| 脚本 | 用途 |
|---|---|
| `scripts/flash-hunt.ps1` | 50ms 轮询所有可见控制台窗口 + 每秒进程快照 diff，抓「一闪而过」和「停在屏幕上」两类，命中时打印 own/par 两条命令行 |
| `scripts/audit-popup-sources.ps1` | 只读体检：当前可见控制台窗口、计划任务里「裸控制台动作 / 裸 .bat」清单（区分已收编/未收编）、命令行里带 `tasklist|wmic|curl|spawn` 的长驻进程 |
| `scripts/hidden-runner.vbs` | 隐藏启动包装模板，供计划任务 / 快捷方式 / Run 键复用 |

## 四类元凶（按命中率排序）

| 类别 | 特征 | 修法 |
|---|---|---|
| **A. Python 子进程没带窗口标志** | 父进程是 `DETACHED_PROCESS`/无控制台的 runner，它 `subprocess.Popen/run` 一次就弹一个 | `creationflags=CREATE_NO_WINDOW`；孙进程还要拉子进程时改用 `STARTUPINFO(SW_HIDE)` 给子进程一个**隐藏的控制台**，让孙进程继承 |
| **B. 计划任务动作直接跑控制台程序 / 裸 `.bat`** | 一闪而过（亚秒）或**停留到脚本结束**；父进程是 `svchost -k netsvcs -s Schedule`；程序自己写的 `-WindowStyle Hidden` 不算数 | 动作改成 `wscript.exe` + `hidden-runner.vbs <case>`（`WshShell.Run cmd, 0, True` 在 CreateProcess 阶段就隐藏） |
| **C. 长驻 watchdog 每 N 秒轮询控制台小工具** | 每 10~30 秒稳定弹；父进程长驻，循环里调 `tasklist`/`wmic`/`curl` | 同上，给循环里的每次 spawn 加隐藏标志 |
| **D. Node/Electron spawn** | 只在某次工具调用时闪 | `windowsHide: true`（execa 默认即 true）；先确认 vendor 代码有没有带，别急着改 vendor |

## 快速开始

```powershell
# 0) 体检一次（只读，不动任何东西）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\audit-popup-sources.ps1

# 1) 抓现形：跑 20 分钟，期间正常用电脑
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\flash-hunt.ps1 -Minutes 20 -LogPath F:\User\Temp\flash-hunt.log

# 2) 看命中
Select-String -Path F:\User\Temp\flash-hunt.log -Pattern '^\[FLASH'
```

日志里 `[FLASH ...]` 是可见窗口（带 `own cmd` / `par cmd` 两条命令行，直接指向 spawn 点）；
`[PROC ...]` 是**没有可见窗口**但属于控制台类的进程，用来定位一闪而过的来源。
验收只看有没有**新增** `[FLASH]`；结尾行的 `flash_count` 含启动瞬间的基线 GUI 窗口，不是弹窗数。

## 隐藏包装：为什么是 wscript + VBS

Windows 的任务计划器（以及快捷方式、`Run` 键）启动控制台程序时，**先创建可见的 console，再把程序挂上去**。所以：

- 给程序加 `-WindowStyle Hidden`、让程序自己 `Start-Process -WindowStyle Hidden`：**太晚了**，第一个窗口已经出现过；
- 用 `conhost.exe --headless`（Win11 部分版本）：行为不稳定，别依赖；
- 唯一干净的做法：让**启动器本身**在 `CreateProcess` 时就要求隐藏窗口 —— 这正是 `WshShell.Run cmd, 0, True` 里的第二个参数 `0`（`SW_HIDE`）。

```powershell
# 把某个计划任务的动作换成隐藏包装（先备份 XML）
Export-ScheduledTask -TaskPath '\' -TaskName 'MyTask' |
  Set-Content 'F:\User\Temp\MyTask.before.xml' -Encoding Unicode

Set-ScheduledTask -TaskPath '\' -TaskName 'MyTask' -Action (New-ScheduledTaskAction `
  -Execute 'C:\Windows\System32\wscript.exe' `
  -Argument '"C:\Program Files\cmd\hidden-runner.vbs" my-case')

Get-ScheduledTaskInfo -TaskName 'MyTask' | Select LastRunTime, LastTaskResult, NextRunTime
```

`hidden-runner.vbs` 里对应加一段：

```vb
  Case "my-case"
    Cmd = "cmd /c """"E:\my\run.bat"""""                      ' 批处理：四段引号
  Case "my-guard"
    Cmd = """C:\...\pwsh.exe"" -NoProfile -File ""E:\...\guard.ps1"""   ' 控制台程序：三段引号
```

要点（都是实测出来的，别自创）：

- **引号写法不是关键**：`cmd /c ""X""`、`cmd /c """"X"""""`、裸 `"X"` 三种写法的子进程 `MainWindowHandle` 全是 0。真正决定隐藏的是 `Run Cmd, 0, True` 的 `0`。
- **UTF-16 LE + BOM**：vbs 里含中文路径时必须存 UTF-16LE（带 BOM），UTF-8 会被 `wscript` 误解析。
- **探针只用 `cscript`**：`WScript.Echo` 在 `wscript` 下等于 `MsgBox` —— 排查弹窗的人自己会弹一个模态框出来。校验解析用 `cscript //nologo //T:10 x.vbs`（无参 → exit 1，未知 case → exit 2）。
- **SYSTEM / 服务账号的任务不用管**：它们跑在会话 0，桌面上根本看不见。
- **只收编交互式（InteractiveToken）任务**：改动作时不要顺手改触发器和身份。

## 验收口径

1. `Get-Process | Where-Object { $_.MainWindowHandle -ne 0 }` 里**没有任何控制台 exe**（只剩浏览器、输入法、资源管理器等 GUI）；
2. 后置检测器 5~20 分钟，`^\[FLASH` 命中数为 0；
3. 计划任务类改动要**双证**：下一次真实触发后 `LastTaskResult=0` + 业务产出文件/日志确实更新，且该任务运行期间检测器无命中；
4. 长驻进程类改动：确认 PID 变了、启动时间在打补丁之后、其子进程 `MainWindowHandle=0`（老进程还活着 = 白修）。

## 实战案例（同一台机器，2026-10）

- **裸 `.bat` 任务**：每日 04:10 的 `\server-ops-skeleton` 动作是 `"E:\...\run-snapshot.bat"`，`cmd /c ""...bat""` 的父进程是任务计划器、`MainWindowHandle=59313510`，**一次停留在屏幕上 3 分多钟**，一天还弹了 4 次（另几次是别的会话手动 `schtasks /run`）。改成 `wscript.exe + hidden-runner.vbs server-ops-snapshot` 后：`LastTaskResult=0`、业务日志照常、窗口消失。
- **`-WindowStyle Hidden` 的幻觉**：三个登录任务直接跑 `pwsh.exe -WindowStyle Hidden`，登录瞬间仍会闪 —— 因为 `-WindowStyle` 是程序启动**之后**才生效。收进同一个包装后不再闪。
- **自己弹自己**：排查时用 `wscript.exe` 跑了一个里面写着 `WScript.Echo` 的探针，屏幕上蹦出 `Windows Script Host / 800A03EA` 模态框。教训：探针一律 `cscript`，并且**先从 `F:\User\Temp` 这类无害目录跑**。

## 安装到 DSH

```powershell
# 把本仓库放进 harness 的 skills 目录（路径按你的安装位置改）
git clone https://github.com/ksoulness/windows-popup-flash "$env:USERPROFILE\skills\windows-popup-flash"
# 或在 agents-home 里：
#   <DSH install>\agents-home\skills\windows-popup-flash\
```

技能是纯 Markdown + PowerShell，宿主下次加载 `windows-popup-flash` 时生效，无需重启。

## 文件清单

```
SKILL.md                      技能本体（完整判定/修法/验收流程）
scripts/flash-hunt.ps1        闪窗检测器（50ms 轮询 + 进程 diff）
scripts/audit-popup-sources.ps1  一次性只读体检
scripts/hidden-runner.vbs     隐藏启动包装模板
```

## License

MIT
