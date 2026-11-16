# Starts the screensaver on this machine and every machine in machines.txt at the same moment. This is the
# Windows edition of test.sh; start it with test.cmd, from a Command Prompt or PowerShell window in this folder.
#
#   test                  start it and leave it: it stays until someone touches that machine
#   test 15               show it for 15 seconds, then close it again
#   test Main-PC nuc      only on these machines (also after a number of seconds); this machine goes by
#                         its computer name
#
# First logs in to each machine in turn, asking for its user name and password where they are not remembered
# yet (see common.ps1), then starts them all together. Each machine needs the screensaver installed (deploy)
# and someone logged in to the desktop.

. (Join-Path $PSScriptRoot 'common.ps1')

$seconds = ''
$names = @()
foreach ($argument in $args) {
    if ("$argument" -match '^\d+$' -and -not $seconds -and $names.Count -eq 0) { $seconds = "$argument" }
    elseif ("$argument" -match '^-') { Show-Usage $PSCommandPath }
    else { $names += "$argument" }
}

# What runs on each machine is in show-linux.sh, show-macos.sh and show-windows.ps1.
$commands = @{
    windows = Get-WindowsCommand ("`$seconds = `"$seconds`"`n" + [IO.File]::ReadAllText((Join-Path $here 'show-windows.ps1')))
    linux = Get-UnixCommand ([IO.File]::ReadAllText((Join-Path $here 'show-linux.sh'))) $seconds
    macos = Get-UnixCommand ([IO.File]::ReadAllText((Join-Path $here 'show-macos.sh'))) $seconds
}

$ready = @()
foreach ($machine in @(Get-Machines)) {
    if ($names.Count -and $names -notcontains $machine.Name) { continue }
    if (-not (Test-Reachable $machine.Address)) {
        '{0,-18} {1,-7} {2}' -f $machine.Name, 'skipped', 'no answer on the SSH port (see README.md)' | Write-Host
        continue
    }
    $connection = Connect-Machine $machine
    if ($connection) { $ready += @{ Name = $machine.Name; System = $machine.System; Connection = $connection } }
    else { '{0,-18} {1,-7} {2}' -f $machine.Name, 'skipped', 'could not log in' | Write-Host }
}
$thisToo = ($names.Count -eq 0) -or ($names -contains $thisMachine)
$count = $ready.Count
if ($thisToo) { $count++ }
if ($count -eq 0) { Write-Host 'no machine to start it on'; exit 1 }

if ($seconds) { Write-Host "showing the screensaver for $seconds seconds on $count machines..." }
else { Write-Host "starting the screensaver on $count machines; it stays until someone touches the machine..." }

# Each machine gets an ssh of its own, running by itself, with what it prints kept in a file until all are done.
$logs = Join-Path $dataDir 'test-logs'
New-Item $logs -ItemType Directory -Force | Out-Null
$number = 0
foreach ($entry in $ready) {
    $number++
    $entry.Log = Join-Path $logs "$number.txt"
    $target = $entry.Connection.Target
    $env:MATRIX_PASSWORD = $entry.Connection.Password   # the new ssh takes over the password as it is at this moment
    $line = "ssh $($sshOptions -join ' ') $target `"$($commands[$entry.System])`" > `"$($entry.Log)`" 2>&1 < nul"
    if ($sshAsks -and -not (Test-Login $target -KeyOnly)) {
        # an old ssh asks for the password at the keyboard, which only one can do at a time
        & cmd /c $line
        $entry.Code = $LASTEXITCODE
    } else {
        $entry.Process = Start-Process cmd.exe -ArgumentList "/c $line" -WindowStyle Hidden -PassThru
        $null = $entry.Process.Handle   # or its exit code is lost once it has ended
    }
}
$env:MATRIX_PASSWORD = ''

$anyFailed = $false
if ($thisToo) {
    $scr = Join-Path $dataDir 'Matrix.scr'
    if (-not (Test-Path $scr)) { $result = 'FAILED'; $said = 'not installed: run deploy'; $anyFailed = $true }
    elseif (Get-Process Matrix -ErrorAction SilentlyContinue) { $result = 'ok'; $said = 'already showing' }
    else {
        Start-Process $scr -ArgumentList '/s'
        $result = 'ok'
        $said = 'started'
        if ($seconds) {
            Start-Sleep ([int]$seconds)
            Stop-Process -Name Matrix -Force -ErrorAction SilentlyContinue
            $said = 'shown'
        }
    }
    '{0,-18} {1,-7} {2}' -f 'this machine', $result, $said | Write-Host
}
foreach ($entry in $ready) {
    if ($entry.Process) {
        $entry.Process.WaitForExit()
        $entry.Code = $entry.Process.ExitCode
    }
    $result = 'ok'
    if ($entry.Code -ne 0) { $result = 'FAILED'; $anyFailed = $true }
    $said = ''
    if (Test-Path $entry.Log) {
        $said = (@(Get-Content $entry.Log) | Where-Object { $_ -notmatch '^(#< CLIXML|<Objs )' }) -join '  '
        if ($said.Length -gt 400) { $said = $said.Substring(0, 400) }
        Remove-Item $entry.Log -ErrorAction SilentlyContinue
    }
    '{0,-18} {1,-7} {2}' -f $entry.Name, $result, $said | Write-Host
}
if ($anyFailed) { exit 1 }
