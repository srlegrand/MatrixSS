# Shows the screensaver now on this Windows machine; test.sh and test.ps1 run it on each one, with a first
# line in front that sets $seconds: "" to leave it until someone touches the machine, or a number of seconds.
#
# Windows gives an SSH login no access to the screen, so the screensaver is started through a scheduled task,
# which runs on the desktop of the logged-in user. A task cannot start a .scr file, so it runs a copy named .exe.
$ProgressPreference = "SilentlyContinue"
$scr = Join-Path $env:LOCALAPPDATA "MatrixScreensaver\Matrix.scr"
$exe = Join-Path $env:LOCALAPPDATA "MatrixScreensaver\MatrixTest.exe"
if (-not (Test-Path $scr)) { [Console]::Error.WriteLine("not installed for $(whoami): run ./deploy.sh"); exit 1 }
if (Get-Process MatrixTest -ErrorAction SilentlyContinue) {
    if (-not $seconds) { "already showing"; exit 0 }
    Stop-Process -Name MatrixTest -Force
    Start-Sleep 1
}
try {
    Copy-Item $scr $exe -Force
    $action = New-ScheduledTaskAction -Execute $exe -Argument "/s"
    $who = New-ScheduledTaskPrincipal -UserId (whoami) -LogonType Interactive
    $rules = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName MatrixTest -Action $action -Principal $who -Settings $rules -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName MatrixTest -ErrorAction Stop
} catch { [Console]::Error.WriteLine("could not start it through a scheduled task: $($_.Exception.Message)"); exit 1 }
Start-Sleep 3
$up = [bool](Get-Process MatrixTest -ErrorAction SilentlyContinue)
if (-not $up) {
    $code = "0x{0:X}" -f (Get-ScheduledTaskInfo -TaskName MatrixTest).LastTaskResult
    $sessions = (quser 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -replace "^[ >]", "" -split " +")[0] }) -join ","
    [Console]::Error.WriteLine("it did not come up (task result $code). Logged in at the screen: $sessions; you are $(whoami)")
    exit 1
}
if (-not $seconds) { "started"; exit 0 }
Start-Sleep ([Math]::Max(1, [int]$seconds - 3))
Stop-Process -Name MatrixTest -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName MatrixTest -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep 1
Remove-Item $exe -ErrorAction SilentlyContinue
"shown"
