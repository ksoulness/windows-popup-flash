# Windows 高频弹窗检测器（flash-hunt）
# 用途：50ms 轮询所有可见控制台窗口 + 每 1s 进程快照 diff，抓「隔一会儿弹一下」的控制台窗口。
# 兼容 Windows PowerShell 5.1 与 pwsh 7（不用 WMI 事件，纯轮询）。
# 用法：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File flash-hunt.ps1 -Minutes 20 -LogPath F:\User\Temp\flash-hunt.log
# 日志解读：
#   [FLASH ...] = 可见控制台窗口（真弹窗），后跟 own/par 两行 cmdline 定位 spawn 链。
#   [PROC  ...] = 新出现的控制台类进程（捕捉 <50ms 一闪而过的）。
#   验收只看有没有新增 [FLASH] 事件；结束行 flash_count 含启动时基线 GUI 窗口数，不是弹窗数。
# 误报：grep 日志请用 ^\[FLASH 锚定行首；检测器自己的命令行含 "[FLASH" 字样，会被记进 [PROC] 行的 cmd 字段。

param(
  [int]$Minutes = 15,
  [string]$LogPath = ''
)
$ErrorActionPreference = 'SilentlyContinue'

if (-not $LogPath) {
  $LogPath = Join-Path $env:TEMP ('flash-hunt-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
}

# 控制台类可执行文件。窗口轮询用 ProcessName（无 .exe）；进程快照用 Win32_Process.Name（有 .exe）。
$names = @(
  'python','pythonw','python3','py','cmd','powershell','pwsh','conhost',
  'tasklist','wmic','find','findstr','curl','netstat','cscript','wscript',
  'bash','sh','git','node','npm','npx','pip','adb','fastboot','openssl',
  'ssh','scp','sftp','ftp','whoami','where','reg','schtasks','timeout',
  'ping','tracert','ipconfig','nslookup','robocopy','xcopy','tar','7z',
  'git-bash','mintty','busybox','awk','sed','grep','wt','WindowsTerminal'
)

function Get-CmdLine([int]$ProcessId) {
  (Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue).CommandLine
}
function Write-Log([string]$Text) {
  Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value $Text
}

$end = (Get-Date).AddMinutes($Minutes)
$seenWin = @{}    # pid -> 已记录的可见窗口
$seenProc = @{}   # pid -> 已记录的进程

# 基线：启动时已存在的窗口/进程不算新事件
Get-Process -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne 0 } |
  ForEach-Object { $seenWin[$_.Id] = $true }

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $names -contains ($_.Name -replace '\.exe$', '') } |
  ForEach-Object { $seenProc[$_.ProcessId] = $true }

Write-Log ('[hunt] start ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' minutes=' + $Minutes + ' log=' + $LogPath)
$nextProc = Get-Date

while ((Get-Date) -lt $end) {
  # 1) 50ms 窗口轮询：任何可见控制台窗口
  $win = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 -and $names -contains $_.ProcessName }
  foreach ($p in $win) {
    if (-not $seenWin.ContainsKey($p.Id)) {
      $seenWin[$p.Id] = $true
      $c = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue
      Write-Log ('[FLASH {0}] pid={1} name={2} title={3}' -f (Get-Date -Format 'HH:mm:ss.fff'), $p.Id, $p.ProcessName, $p.MainWindowTitle)
      Write-Log ('    own cmd: {0}' -f $c.CommandLine)
      Write-Log ('    par cmd: {0}' -f (Get-CmdLine $c.ParentProcessId))
    }
  }

  # 2) 每 1s 进程快照 diff：捕捉一闪而过（<50ms）的进程
  if ((Get-Date) -ge $nextProc) {
    $nextProc = (Get-Date).AddSeconds(1)
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $names -contains ($_.Name -replace '\.exe$', '') }
    foreach ($c in $procs) {
      if (-not $seenProc.ContainsKey($c.ProcessId)) {
        $seenProc[$c.ProcessId] = $true
        Write-Log ('[PROC {0}] pid={1} name={2} ppid={3} cmd={4}' -f (Get-Date -Format 'HH:mm:ss.fff'), $c.ProcessId, $c.Name, $c.ParentProcessId, $c.CommandLine)
      }
    }
  }

  Start-Sleep -Milliseconds 50
}

Write-Log ('[hunt] end ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' flash_count=' + $seenWin.Count + ' proc_new=' + $seenProc.Count)
