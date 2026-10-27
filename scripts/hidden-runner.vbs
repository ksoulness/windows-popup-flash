' hidden-runner.vbs - launch a console program with a HIDDEN console window.
'
' Why: Windows Task Scheduler creates a VISIBLE console before it starts a
' console program (or a .bat/.cmd).  Anything the program itself does later
' (-WindowStyle Hidden, SW_HIDE in its own Start-Process, ...) happens after
' that first visible window already appeared.  This wrapper calls
' WshShell.Run cmd, 0, True -> CreateProcess is asked for a hidden window
' from the very beginning, so nothing flashes and nothing stays on screen.
'
' Usage: make the scheduled task action
'     Program : C:\Windows\System32\wscript.exe
'     Arguments: "C:\Program Files\cmd\hidden-runner.vbs" <case-name>
' then add a matching Case below.  Run the SAME wrapper from shortcuts,
' Run keys, or anything else that used to pop a console.
'
' Verify without running the real (possibly destructive) command:
'     cscript //nologo //T:10 "C:\Program Files\cmd\hidden-runner.vbs"
'         -> exit 1 (no argument)
'     cscript //nologo //T:10 "C:\Program Files\cmd\hidden-runner.vbs" nope
'         -> exit 2 (unknown case)
'   Both prove the script parses.  Do NOT use wscript.exe for probing:
'   WScript.Echo under wscript is a modal MsgBox.
'
' Adding a case:
'   - batch file  : Cmd = "cmd /c """"C:\path\to\task.bat"""""
'   - console exe : Cmd = """C:\path\to\app.exe"" --arg ""C:\path with space\file.txt"""
'   If your paths contain non-ASCII characters, save THIS file as
'   UTF-16 LE with BOM, otherwise wscript may mis-parse it.

Set WshShell = CreateObject("WScript.Shell")
Set Args = WScript.Arguments

If Args.Count < 1 Then
  WScript.Quit 1
End If

Mode = LCase(Args(0))

Select Case Mode
  ' ---- examples -------------------------------------------------------
  Case "example-batch"
    Cmd = "cmd /c """"C:\path\to\your-task.bat"""""
  Case "example-exe"
    Cmd = """C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -File ""C:\path\to\your-guard.ps1"""
  ' ---- add your own cases above this line ------------------------------
  Case Else
    WScript.Quit 2
End Select

WshShell.Run Cmd, 0, True
Set WshShell = Nothing
