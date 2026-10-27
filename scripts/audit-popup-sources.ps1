<#
.SYNOPSIS
  一次性体检：找出「会往桌面上弹控制台窗口」的可疑来源（计划任务 + 当前可见窗口 + 常驻进程）。

.DESCRIPTION
  不修改任何东西，只读。回答三个问题：
    1) 现在还有没有可见的控制台窗口？它的父进程是谁？
    2) 哪些计划任务的动作是「裸控制台程序 / 裸 .bat/.cmd」—— 这是最常见的周期弹窗元凶；
       哪些已经收编到 wscript + hidden-runner.vbs 隐藏包装里。
    3) 哪些长驻进程每 N 秒轮询 tasklist/wmic/curl 等控制台小工具（父进程不带隐藏标志就会闪）。

.PARAMETER TaskPath
  只检查某个任务文件夹，默认 '\'（根）。检查登录启动的任务时用 '\UserStartup\' 之类。

.PARAMETER ShowAll
  连 SYSTEM/服务账号的任务一起列（它们在会话 0 跑，桌面上看不见，通常可以忽略）。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File audit-popup-sources.ps1

.EXAMPLE
  # 只列出「装上了但动作还是裸命令」的交互式任务
  .\audit-popup-sources.ps1 | Where-Object { $_.Kind -eq 'RAW' }
#>
[CmdletBinding()]
param(
  [string[]]$TaskPath = @('\'),
  [switch]$ShowAll
)

$ErrorActionPreference = 'SilentlyContinue'

# 会在桌面上出现控制台窗口的可执行文件（按 ProcessName，无 .exe）
$consoleNames = @(
  'cmd','powershell','pwsh','conhost','python','pythonw','py','wscript','cscript',
  'tasklist','wmic','curl','netstat','ssh','scp','git','node','npm','npx','bash','sh',
  'find','findstr','reg','schtasks','timeout','ping','tracert','ipconfig','nslookup',
  'robocopy','xcopy','tar','adb','openssl','whoami','where','7z','git-bash','mintty'
)

function Section([string]$Title) {
  Write-Host ''
  Write-Host ("=== " + $Title + " ===") -ForegroundColor Cyan
}

# ---------------------------------------------------------------- 1. 当前可见窗口
Section '当前可见的控制台窗口（有就说明正在弹 / 还在屏幕上）'
$visible = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $consoleNames -contains $_.ProcessName }
if (-not $visible) {
  Write-Host '  （无）' -ForegroundColor Green
} else {
  foreach ($p in $visible) {
    $c = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)"
    $par = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.ParentProcessId)"
    Write-Host ("  pid={0} name={1} title={2}" -f $p.Id, $p.ProcessName, $p.MainWindowTitle) -ForegroundColor Yellow
    Write-Host ("     own: " + $c.CommandLine)
    Write-Host ("     par: [{0}] {1}" -f $par.Name, $par.CommandLine)
    Write-Host ("     hwnd={0}  started={1}" -f $p.MainWindowHandle, (try { $p.StartTime } catch { '?' }))
  }
}

# ---------------------------------------------------------------- 2. 计划任务
Section '计划任务：动作是裸控制台程序 / 裸 .bat/.cmd 的（周期弹窗元凶）'
$rows = @()
foreach ($tp in $TaskPath) {
  foreach ($t in (Get-ScheduledTask -TaskPath $tp)) {
    $act = @($t.Actions)[0]
    $exe = "$($act.Execute)"
    $arg = "$($act.Arguments)"
    if (-not $exe) { continue }

    $isWrapped = ($exe -match 'wscript\.exe$') -and ($arg -match 'hidden-runner\.vbs')
    $isConsole = ($exe -match '(?i)(cmd|powershell|pwsh|python|pythonw|py|cscript|wscript|bash|node)\.exe$') -or
                 ($exe -match '(?i)\.(bat|cmd)$') -or ($arg -match '(?i)\.(bat|cmd)')

    $principal = $t.Principal
    $isSystem  = ($principal.UserId -match 'SYSTEM|S-1-5-18') -or ($principal.LogonType -eq 'ServiceAccount')
    if ($isSystem -and -not $ShowAll) { continue }
    if (-not $isConsole) { continue }

    $info = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName
    $kind = if ($isWrapped) { 'OK(wscript)' } elseif ($exe -match '(?i)\.(bat|cmd)$') { 'RAW(.bat)' } else { 'RAW(exe)' }
    $rows += [pscustomobject]@{
      Kind      = if ($isWrapped) { 'WRAPPED' } else { 'RAW' }
      Verdict   = $kind
      Task      = ($t.TaskPath + $t.TaskName)
      Trigger   = (@($t.Triggers) | ForEach-Object { $_.CimClass.CimClassName -replace 'MSFT_Task', '' -replace 'Trigger', '' }) -join ','
      Principal = "$($principal.UserId) / $($principal.LogonType)"
      Exec      = $exe
      Args      = $arg
      LastRun   = $info.LastRunTime
      Result    = $info.LastTaskResult
    }
  }
}
if (-not $rows) {
  Write-Host '  （无）—— 计划任务这一层很干净' -ForegroundColor Green
} else {
  $rows | Sort-Object Kind, Task | Format-Table Kind, Task, Trigger, Result, LastRun -AutoSize
  Write-Host '  ↑ RAW = 还没收编，会弹窗；OK(wscript)/WRAPPED = 已走隐藏包装' -ForegroundColor Yellow
  Write-Host '  详情：' -ForegroundColor Yellow
  $rows | Where-Object Kind -eq 'RAW' | ForEach-Object {
    Write-Host ("   - {0}`n       exec: {1}`n       args: {2}" -f $_.Task, $_.Exec, $_.Args) -ForegroundColor Yellow
  }
}

# ---------------------------------------------------------------- 3. 长驻轮询进程
Section '长驻进程：命令行里带控制台小工具调用的（每 N 秒闪一下的典型来源）'
$patterns = 'tasklist|wmic|netstat|curl|where\.exe|schtasks|reg query|/c |subprocess|Popen|child_process|spawn'
$hits = Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match $patterns -and $_.Name -notmatch '^(pwsh|powershell|cmd|conhost)\.exe$' }
if (-not $hits) {
  Write-Host '  （无）' -ForegroundColor Green
} else {
  $hits | ForEach-Object {
    Write-Host ("  pid={0} {1} ppid={2}" -f $_.ProcessId, $_.Name, $_.ParentProcessId)
    Write-Host ("     cmd: " + ($_.CommandLine -replace '\s+', ' ')) -ForegroundColor DarkGray
  }
}

Section '提示'
Write-Host '  · 计划的 RAW 任务：备份 XML → 动作改成 wscript.exe + hidden-runner.vbs <case>（见 README「隐藏包装」）'
Write-Host '  · 想抓一闪而过的窗口：scripts/flash-hunt.ps1 -Minutes 20'
Write-Host '  · 父进程是 svchost -k netsvcs -s Schedule = 任务计划器；是 explorer.exe = 用户/快捷方式启动'
