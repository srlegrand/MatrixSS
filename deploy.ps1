# Installs the Matrix screensaver on this machine and on the others, over SSH. This is the Windows edition
# of deploy.sh; start it with deploy.cmd, from a Command Prompt or PowerShell window in this folder.
#
#   deploy                    this machine and every machine in machines.txt
#   deploy nuc Main-PC        only these (this machine goes by its computer name)
#   deploy -remove [...]      undo
#   deploy -forget            drop the remembered passwords
#
# The first time, asks for the user name and password of each machine as it gets to it, and remembers them
# (see common.ps1): later runs ask nothing. On Linux the same password is given to sudo. A machine that does
# not answer is skipped, with what to do on it. README.md has the whole story.

. (Join-Path $PSScriptRoot 'common.ps1')

$remove = $false
$names = @()
foreach ($argument in $args) {
    if ($argument -match '^--?remove$') { $remove = $true }
    elseif ($argument -match '^--?forget$') { Clear-Remembered; Write-Host 'forgot the remembered passwords'; exit 0 }
    elseif ($argument -match '^-') { Show-Usage $PSCommandPath }
    else { $names += $argument }
}
function Test-Wanted($name) { ($names.Count -eq 0) -or ($names -contains $name) }

$unixFlag = ''
if ($remove) { $unixFlag = ' --remove' }
$folder = '/tmp/matrix-screensaver'   # the files go to a folder of their own on the machine, which the last command there removes again
# Scripts that were unpacked or checked out on Windows may have Windows line endings, which bash cannot read.
$unixLines = "for f in $folder/*.sh; do tr -d '\r' < `$f > `$f.lf && mv `$f.lf `$f; done"

# Makes sure the password is one that sudo takes on that machine, asking when there is none or sudo refuses it.
# Returns the password, or '' when none was found.
function Get-SudoPassword($machine, $connection) {
    $check = "tr -d '\r' | sudo -k -S -p '' true"   # PowerShell ends what it pipes with a Windows line ending
    $password = $connection.Password
    if ($password) {
        $password | & ssh @sshOptions $connection.Target $check 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $password }
        Write-Host '    sudo does not take the remembered password'
    }
    foreach ($try in 1..3) {
        $password = Read-Password "    $($machine.Name): password of $($connection.User), for sudo"
        if (-not $password) { return '' }
        $password | & ssh @sshOptions $connection.Target $check 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            if (-not $connection.Password) { Set-Remembered $machine.Name $password }
            return $password
        }
        Write-Host '    sudo did not take it'
    }
    ''
}

function Install-Linux($machine, $connection) {
    $target = $connection.Target
    if (-not (Invoke-Remote $target "mkdir -p $folder")) { return $false }
    if (-not (Copy-Remote $target @((Join-Path $here 'install.sh'), (Join-Path $here 'matrix-rain')) "$folder/")) { return $false }
    $password = Get-SudoPassword $machine $connection
    if (-not $password) { return $false }
    $command = "$unixLines; tr -d '\r' | sudo -S -p '' bash $folder/install.sh$unixFlag; s=`$?; rm -rf $folder; exit `$s"
    $password | & ssh @sshOptions $target $command | Out-Host
    $LASTEXITCODE -eq 0
}

function Install-Mac($connection) {
    $target = $connection.Target
    if (-not (Invoke-Remote $target "mkdir -p $folder")) { return $false }
    $files = @((Join-Path $here 'install-macos.sh'), (Join-Path $here 'matrix-rain.c'), (Join-Path $here 'glyphs.h'))
    if (-not (Copy-Remote $target $files "$folder/")) { return $false }
    Invoke-Remote $target "$unixLines; bash $folder/install-macos.sh$unixFlag; s=`$?; rm -rf $folder; exit `$s"
}

function Install-Windows($connection) {
    $target = $connection.Target
    if (-not (Copy-Remote $target @(Join-Path $here 'install.ps1') 'matrix-install.ps1')) { return $false }
    if (-not $remove) {
        if (-not (Copy-Remote $target @(Join-Path $here 'Matrix.scr') 'matrix-rain.scr')) { return $false }
        return (Invoke-Remote $target 'powershell -NoProfile -ExecutionPolicy Bypass -File matrix-install.ps1')
    }
    Invoke-Remote $target 'powershell -NoProfile -ExecutionPolicy Bypass -File matrix-install.ps1 -Remove'
}

$finished = @()
$skipped = @()
$failed = @()

if (Test-Wanted $thisMachine) {
    Write-Host "=== $thisMachine (this machine, windows)"
    if ($remove) { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'install.ps1') -Remove | Out-Host }
    else { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'install.ps1') | Out-Host }
    if ($LASTEXITCODE -eq 0) { $finished += $thisMachine } else { $failed += $thisMachine }
}

if (-not (Test-Path $machinesFile)) {
    Write-Host '(no machines.txt, so no other machines: copy machines.example.txt to machines.txt and fill it in)'
}
foreach ($machine in @(Get-Machines)) {
    if (-not (Test-Wanted $machine.Name)) { continue }
    Write-Host "=== $($machine.Name) ($($machine.Address), $($machine.System))"
    if (@('linux', 'windows', 'macos') -notcontains $machine.System) {
        Write-Host '    machines.txt: the system must be linux, windows or macos'
        $failed += $machine.Name
        continue
    }
    if (-not (Test-Reachable $machine.Address)) {
        Show-NotReachable $machine.System
        $skipped += $machine.Name
        continue
    }
    $connection = Connect-Machine $machine
    if (-not $connection) {
        Write-Host '    could not log in'
        $failed += $machine.Name
        continue
    }
    $worked = switch ($machine.System) {
        'linux' { Install-Linux $machine $connection }
        'macos' { Install-Mac $connection }
        'windows' { Install-Windows $connection }
    }
    if ($worked) { $finished += $machine.Name } else { $failed += $machine.Name }
}
$env:MATRIX_PASSWORD = ''

Write-Host ''
$what = 'installed'
if ($remove) { $what = 'removed' }
$list = 'none'
if ($finished.Count) { $list = $finished -join ' ' }
Write-Host "${what}: $list"
if ($skipped.Count) { Write-Host "skipped, no answer: $($skipped -join ' ')" }
if ($failed.Count) { Write-Host "failed: $($failed -join ' ')"; exit 1 }
