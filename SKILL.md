---
name: windows-popup-flash
description: 排查 Windows「每隔一会儿弹一个控制台窗口（python/cmd/powershell/pwsh/tasklist 等黑框）、打字被抢焦点」时使用：挂 50ms 高精度闪窗检测器抓现行，按父进程链定位 spawn 代码，用 CREATE_NO_WINDOW / STARTUPINFO(SW_HIDE) / wscript 隐藏包装根治并验收；也覆盖「计划任务动作直接是 .bat/.cmd 导致窗口停留分钟级」这一类。触发词：弹窗、闪一下、闪断、黑框、抢焦点、控制台窗口、又弹了、cmd 窗口一直开着、计划任务弹窗。
argument-hint: "[hunt|fix|verify]"
---

# Windows 频繁弹窗排查

默认 `hunt`（先抓现形）。目标：找出「周期性抢焦点的控制台窗口」并根治，不是加隐藏补丁蒙混。

## 铁律

- **先抓现行再动手**。用户说「隔一会儿弹一下」时，挂检测器 10–20 分钟拿 [FLASH] 证据（name/pid/ppid/cmdline），不要凭猜。
- 修在 **spawn 树的最顶端**：控制台被父进程继承，修最上面的 spawn 点能隐藏整棵子树。
- **一次 0 命中不算结论**：确认检测器真的在跑、名字清单覆盖了那个 exe、日志行数在增长。
- 修完必须**重启该长驻进程并用新代码跑**，再挂检测器验收；老进程还活着 = 白修。
- **验证探针一律 `cscript`，绝不 `wscript`**（`WScript.Echo` 在 wscript 下是 MsgBox，会往用户屏幕弹模态框 —— 排查弹窗的人自己弹窗，最丢人）；每次动手前先备份（计划任务导 XML、vbs 复制 `.bak-<ts>`）。
- **改完必须落文档**：谁再注册/重建这个任务、谁再写这个 spawn，照抄文档才不会复发（本机写在 `E:\Code\server-ops\docs\10-config-as-code.md` §8 + README 红线）。

## hunt：抓现形

用 `scripts/flash-hunt.ps1`（Windows PowerShell 5.1 与 pwsh 7 均可用）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<本技能目录>\scripts\flash-hunt.ps1" -Minutes 20 -LogPath F:\User\Temp\flash-hunt.log
```

放后台跑，别占前台。日志解读：

- `[FLASH HH:mm:ss.fff] pid=… name=… title=…` 后跟 `own cmd:` / `par cmd:` 两行 —— 这就是元凶进程和它爹（ppid 用 Win32_Process.ParentProcessId 拿）。
- `[PROC …]` 是每 1s 进程快照 diff（捕捉 <50ms 的闪现），只要它没升级成 [FLASH] 就说明没窗口。
- **误报陷阱**：grep 日志必须锚定行首 —— `^\[FLASH` 或 `Select-String -SimpleMatch '[FLASH '`。检测器自己的命令行里含 "[FLASH" 字样，会被记进 [PROC] 行的 cmd 字段造成假阳性。脚本把启动时现存窗口计入基线，结束行 `flash_count` 含基线数（GUI 窗口也算），判断只看有没有**新增** [FLASH] 事件，不看总数。

检测器两个已知坑（本会话踩过）：

- pwsh 7 **没有** `Register-WmiEvent`/WMI cmdlet；Windows PowerShell 5.1 有。脚本已弃 WMI 事件、纯轮询，两个版本通用。
- PS 5.1 里 `Register-WmiEvent … -Action {…} | Out-Null` 是**解析错误**（-Action 脚本块后不能接管道）。需要事件时去掉管道、分号另起一行。

## 根因分类与修法（按命中率排序）

### A. Python 子进程没带窗口标志（最常见、最隐蔽）

父进程是分离进程（`creationflags=DETACHED_PROCESS`，无控制台）时，它 spawn 的每个 `subprocess.Popen/run` **不带窗口标志**，Windows 就为子进程新建一个**可见控制台**。

- 单层子进程、子进程不再 spawn 别的：加 `creationflags=subprocess.CREATE_NO_WINDOW`（子进程无控制台）。
- 子进程还要 spawn 孙进程（如 runner 再拉 powershell/并行脚本）：给子进程一个**隐藏的控制台**，孙进程自动继承隐藏：
  ```python
  si = subprocess.STARTUPINFO()
  si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
  si.wShowWindow = subprocess.SW_HIDE
  subprocess.Popen([...], ..., startupinfo=si)
  ```
- 真实案例（BRAINqunat）：`research/scripts/dispatch.py` 两处——`_spawn()` 拉 RUN.py（用 SW_HIDE，因 RUN.py 还要拉 powershell/run_study_par）与 `alive()` 调 tasklist（用 CREATE_NO_WINDOW）；`ensure_services.py` 的 wmic、`start_scheduler.py` 的 tasklist 同款加 CREATE_NO_WINDOW。

### B. 计划任务动作直接跑控制台 exe

任务计划器**先建可见控制台再启动程序**；程序里的 `-WindowStyle Hidden` 是启动之后才隐藏 → 亚秒闪窗。`-WindowStyle Hidden` 在「任务动作」位置**不算数**。

- 根治：动作改指 `C:\Windows\System32\wscript.exe "…\hidden-runner.vbs" <case>`，vbs 里 `WshShell.Run cmd, 0, True`（CreateProcess 时即隐藏，不闪）。
- vbs 含中文路径必须存 **UTF-16 LE（带 BOM）**；UTF-8 的 vbs 在中文 Windows 上会被 wscript 误解析。写完用 cscript 探针验证可解析（探针故意 exit 2 看它跑没跑起来）。
- **SYSTEM 账号**的任务在会话 0 运行，桌面上根本不可见 → 跳过。
- **AtLogOn** 任务只在登录/重启闪一次，非周期 → 单独列给用户决定，别当周期元凶。
- 真实案例：flclash-proxy-guard(PT2M)、MacroDeck Watchdog Injector(PT1H)、NAS Drive Watchdog(PT10M) 等 7 个任务统一改 hidden-runner.vbs。

#### B1（最容易漏判）：动作就是 `.bat` / `.cmd` —— 窗口不是闪一下，而是留到脚本结束

任务计划器**为批处理先建一个可见 console**，脚本跑多久窗口就在屏幕上留多久（分钟级），期间持续抢焦点。这类**不会**表现为 `[FLASH]` 一闪而过，而是整个运行期都能被 `MainWindowHandle` 抓到；日志里是 `cmd.exe` + `conhost.exe`，父进程 = **任务计划器**。

判定三件套：

```powershell
# 1) 目标 cmd 的父进程是不是任务计划器（svchost -k netsvcs -p -s Schedule）
Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | ForEach-Object {
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)"
  [pscustomobject]@{ Pid=$_.ProcessId; Win=(Get-Process -Id $_.ProcessId).MainWindowHandle; Cmd=$_.CommandLine; Parent=$p.CommandLine }
}
# 2) 哪些任务的动作是裸 bat/cmd
Get-ScheduledTask | ? { $_.Actions.Execute -match '\.(bat|cmd)$' -or $_.Actions.Arguments -match '\.(bat|cmd)' } |
  select TaskName,@{n='Exec';e={$_.Actions.Execute}},@{n='Args';e={$_.Actions.Arguments}}
# 3) 多久跑一次：直接数脚本自写 run.log 里的 `=== ` 头最快（TaskScheduler/Operational 常 IsEnabled=False，查不到历史）
```

真实案例（2026-10-27）：`\server-ops-skeleton`（每日 04:10）动作 = 裸 `"E:\Code\server-ops\tools\run-snapshot.bat"`；`cmd /c ""…run-snapshot.bat""` 父进程 `svchost -k netsvcs -s Schedule`、`MainWindowHandle=59313510`，从 01:02:48 挂到 01:06 之后；`snapshots/run.log` 的 4 个 `=== ` 头（00:54:41 / 01:01:07 / 01:02:48 / 01:07:22）= 4 次弹窗。**「日触发任务为何一小时弹 4 次」的答案通常是别的会话手动 `schtasks /run`**，别先怀疑触发器。

改法（照抄，别自创）：

```powershell
# 0) 先备份 XML，可回滚
Export-ScheduledTask -TaskPath '\' -TaskName 'X' | Set-Content 'F:\User\Temp\X.before.xml' -Encoding Unicode
# 1) 动作换 wscript + 共用包装（case 名先在 vbs 里加好）
Set-ScheduledTask -TaskPath '\' -TaskName 'X' -Action (New-ScheduledTaskAction `
  -Execute 'C:\Windows\System32\wscript.exe' `
  -Argument '"C:\Program Files\cmd\hidden-runner.vbs" my-case')
# 2) 核对动作/触发/身份没被顺手改掉
(Get-ScheduledTask -TaskName 'X').Actions | fl Execute,Arguments
Get-ScheduledTaskInfo -TaskName 'X' | fl LastRunTime,LastTaskResult,NextRunTime
```

vbs 对应 case（批处理用四段引号，控制台 exe 用三段）：

```vb
  Case "my-case"
    Cmd = "cmd /c """"E:\Code\my-task\run.bat"""""                        ' 批处理
  Case "my-guard"
    Cmd = """C:\...\pwsh.exe"" -NoProfile -File ""E:\...\guard.ps1"""     ' 控制台 exe
```

**引号不是关键**：`cmd /c ""X""`、`cmd /c """"X"""""`、裸 `"X"` 三种写法子进程全部 `MainWindowHandle=0`；决定隐藏的是 `Run Cmd, 0, True` 里的 **0**。别在引号上空转。

**pwsh 用完整包路径** `C:\Users\Administrator\AppData\Local\Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe`，不要用 `WindowsApps\pwsh.exe` 应用别名 stub（非交互上下文更脆）。

#### B2 探针纪律（踩过两次，直接弹到用户脸上）

- **探针一律 `cscript`，绝不 `wscript`**：`WScript.Echo` 在 `wscript` 下 = `MsgBox`，会在用户屏幕弹 `Windows Script Host` 模态框。要打印命令行就用 `cscript //nologo probe.vbs`。
- 语法/结构校验：`cscript //nologo //T:10 <vbs>`，**无参 → exit 1、未知 case → exit 2**（全文编译 = 语法检查），不必写专用测试分支。
- 想知道某 case 拼出什么命令行：用脚本解析 VBS 转义（`Cmd = "…"` 去首尾引号、`""`→`"`）与任务原参数**逐字比对**，比实跑安全。
- **别拿会重启本机服务的脚本做实验**（例：`REGROUP.cmd` 会 stop/start DSH 3079 = 杀掉当前会话）。
- 探针目标只用 `F:\User\Temp\probe-*.cmd` 这类无害脚本；**探针别落地成 `.vbs`** —— 本机有未登记安全软件会当场删掉新写的 vbs（Defender 是关的、威胁记录为空，文件照样消失）。验证隐藏启动更可靠的是**拿生产里在跑的同构任务当证据**（例：`\DSH-Windsh-Gateway` 的 pwsh 父进程是任务计划器、`MainWindowHandle=0`）。
- `timeout /t N /nobreak` 在隐藏 console 里正常工作（rc=0、耗时准确），批处理迁到隐藏启动不用换 ping。

#### B3 收编判据

- 只收编 `InteractiveToken` 任务；`SYSTEM`/`ServiceAccount` 在会话 0，桌面不可见，不动（例：`\PolyMarket-Windows-Time-Audit-15m` 每 15 分钟裸跑 powershell，但是 SYSTEM → 无窗）。
- 改动作**不动**触发器与身份；`MultipleInstancesPolicy=IgnoreNew` + `DisallowStartIfOnBatteries=false` 时登录触发正常。
- 改完不必重启正在运行的旧实例（它本来就隐藏），新包装在下次登录/启动生效 —— 但报告里要**说清楚**，别让用户以为已经切过去了。
- 改动落文档（谁再注册任务都得照抄），否则另一会话重建任务时立刻复发：本机写在 `E:\Code\server-ops\docs\10-config-as-code.md` §8 + `README.md` 红线第 4 条 + `tools/run-snapshot.bat` 头注释。

### C. 长驻 watchdog 每 N 秒轮询调控制台工具

同 A，但特征是「每 10~30 秒稳定弹」——父进程长驻、循环里 subprocess 调 tasklist/wmic/ps 查活。**tasklist.exe 是本机 BRAINqunat 的真正元凶**（10~30s 一次，之前修完 RUN.py 后仍弹就是它）。

### D. Node/Electron spawn

统一要求 `windowsHide: true`（execa 默认即 true）。WorkBuddy、DSH harness 本体都合规；别去改 vendor 代码（更新会覆盖），先在源码确认它已带 windowsHide。

## 排查顺序

1. 挂检测器抓 [FLASH]（hunt）：`scripts/flash-hunt.ps1 -Minutes N -LogPath F:\User\Temp\flash-<date>.log`（**参数只有 `-Minutes`/`-LogPath`，写错名字会被静默忽略**）。
2. **先查「窗口留得住」的那类**：`Get-Process cmd,conhost -EA 0 | ? MainWindowHandle -ne 0` —— 如果有，几乎必是计划任务裸 `.bat`/`.cmd`，按 B1 三件套定位，别再等 [FLASH]。
3. 有 [FLASH] 就 pid→ppid 链定位 spawn 代码（grep 父进程源码：`subprocess|Popen|os.system|spawn|execFile`），按 A/C/D 修最高点。
4. 枚举全部计划任务：`Get-ScheduledTask | ? { $_.Actions.Execute -match '(powershell|pwsh|cmd|python|cscript|\.bat|\.cmd)' }`，逐个改 wscript 或确认「SYSTEM/会话0 不可见」或「一次性维护窗口」。
5. 重启长驻进程：杀旧进程树 + **走它原本的启动器**。注意：有些守护进程带自保护，在 DSH 环境会拒绝 run（BRAINqunat 的 ALPHA-LOCK 只认 watchdog 计划任务的干净环境，直接手动拉会秒死并打印 "Read-only status stays allowed"）。
6. 验收（见下），并把结论落成文档/记忆（见 B3 最后一条），否则别的会话重建任务时立刻复发。

## 验收口径

- `Get-Process | Where-Object { $_.MainWindowHandle -ne 0 }` 全机可见窗口里**没有任何控制台 exe**（只剩浏览器/微信/资源管理器等 GUI；用户自己开的 `管理员: …pwsh.exe` 属于正常，别误判）。
- 后置检测器 5–20 分钟：`^\[FLASH` 命中数 = 0（注意结束行的 `flash_count=` 含启动瞬间的基线 GUI 窗口，不是弹窗数，别拿它当命中断言）。
- 确认跑的是新代码：长驻进程 PID 变了 + 启动时间在打补丁之后 + 其子进程 MainWindowHandle = 0。
- **计划任务类改动**要双证：① 下一次真实触发后 `LastTaskResult=0` + 业务产出文件/日志有更新（例：04:10 → task.log 变大、push rc=0）；② 该任务运行期间检测器 `^\[FLASH`=0。危险任务（会重启服务的，如 `\DSHRegroup`）只能等真实触发，禁止 `schtasks /run` 验证。

## 本机速查（Administrator / DSH 3079）

- 已根治：BRAINqunat dispatch（RUN.py SW_HIDE + tasklist CREATE_NO_WINDOW + save 唯一 tmp 竞态修复）、ensure_services/start_scheduler 的 wmic/tasklist、7 个计划任务改 hidden-runner.vbs。
- hidden-runner.vbs：`C:\Program Files\cmd\hidden-runner.vbs`（UTF-16LE+BOM，14 个 case，清单见文件内）。**改它之前先 `Copy-Item` 备份 `.bak-<yyyyMMdd-HHmmss>`**，改完 `Compare-Object` 确认只多了预期那几行。
- 2026-10-27 收编的 5 个任务（动作全部 = `wscript.exe` + `hidden-runner.vbs <case>`）：

  | 任务 | 触发 | case |
  |---|---|---|
  | `\server-ops-skeleton` | 每日 04:10 | `server-ops-snapshot`（批处理） |
  | `\DSHRegroup` | 每日 05:00 | `dsh-regroup`（批处理，会 stop/start 3079） |
  | `\Codex Home Upgrade Guard` | AtLogOn | `codex-home-guard` |
  | `\UserStartup\CodexHomeUpgradeGuard` | AtLogOn | `codex-home-guard` |
  | `\UserStartup\DevSpace MCP` | AtLogOn | `devspace-mcp` |

  首次实跑证据：04:10 snapshot `LastTaskResult=0`（`snapshots/task.log` 2974B、push nas/gcp rc=0）；05:00 regroup `result=0`（`reorg3.log` stop 1.5s → workspace already present → start 9.7s），两次**桌面上都没出现窗口**。回滚 XML 在 `F:\User\Temp\*.before.xml`。
- 检测器可复用：本技能 `scripts/flash-hunt.ps1`（或历史 `F:\User\Temp\flash-hunt4.ps1`）。**参数是 `-Minutes`（默认 15）、`-LogPath`**；写错参数名（如 `-DurationSeconds`）不会报错，会被静默忽略然后按 15 分钟跑 —— 以为"只挂了 3 分钟"其实占着 15 分钟。
- 验证"定时任务改完真的不弹了"的两种口径：① 等下一次真实触发，看 `LastTaskResult=0` + 产出日志 + 事后 `^\[FLASH` 为 0；② 立刻 `schtasks /run /tn X`（仅限安全任务）+ 跑后 3 分钟检测器，并查子进程 `MainWindowHandle=0`。**会重启服务的任务（`\DSHRegroup`）只能走 ①**。
- 已知无害但会动：WorkBuddy 每 ~10s 的 powershell（windowsHide:true，无窗口，别动）；Codex Home Upgrade Guard / DevSpace MCP 两个 AtLogOn 一次性闪。
- 一次性维护窗口（dsh-purge-archived 等）动作无 -WindowStyle Hidden 会弹一次，属正常维护，别当周期性元凶。
