# Shared by deploy.ps1 and test.ps1: the list of machines, and reaching them over SSH from Windows 10 or 11.
# Works with the PowerShell and the ssh that are part of Windows; nothing needs installing.
#
# Connect-Machine asks for a machine's user name and password the first time. The user name is then remembered
# in machines.txt and the password in %LOCALAPPDATA%\MatrixScreensaver\passwords.txt, encrypted by Windows for
# your account (nobody else, and no other computer, can read it), so later runs ask nothing. A password that
# has stopped working is asked for again. Machines that have this machine's SSH key need no password to log in.
# deploy -forget drops the remembered passwords.
#
# The ssh of Windows cannot keep a connection open the way the Linux one can, so every step logs in again,
# with the password handed to ssh by a helper (askpass.cmd) instead of typed.

$ErrorActionPreference = 'Continue'
$OutputEncoding = New-Object Text.UTF8Encoding $false   # how a password is piped to ssh for sudo: no byte-order mark
$here = $PSScriptRoot
$machinesFile = Join-Path $here 'machines.txt'
$thisMachine = $env:COMPUTERNAME
$dataDir = Join-Path $env:LOCALAPPDATA 'MatrixScreensaver'
$passwordFile = Join-Path $dataDir 'passwords.txt'
$sshOptions = @('-o', 'ConnectTimeout=6', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'NumberOfPasswordPrompts=1')

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Host 'ssh is not on this machine. In PowerShell as administrator, run:'
    Write-Host '  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0'
    exit 1
}

# ssh takes a password from a program, not from a variable: this one hands over $env:MATRIX_PASSWORD.
New-Item $dataDir -ItemType Directory -Force | Out-Null
$askpass = Join-Path $dataDir 'askpass.cmd'
Set-Content $askpass -Encoding ASCII -Value '@powershell -NoProfile -Command "[Console]::Out.Write($env:MATRIX_PASSWORD)"'
$env:SSH_ASKPASS = $askpass
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY = 'none'
$env:MATRIX_PASSWORD = ''

# ssh older than 8.4 (Windows 10 that has not been updated in years) ignores that helper and asks at the keyboard.
$sshVersion = (& cmd /c 'ssh -V 2>&1') -join ' '
$sshAsks = $false
if ($sshVersion -match '_(\d+)\.(\d+)') { $sshAsks = ([int]$Matches[1] -lt 8) -or ([int]$Matches[1] -eq 8 -and [int]$Matches[2] -lt 4) }
if ($sshAsks) {
    Write-Host "This Windows has an old ssh ($sshVersion): it will ask for each machine's password at every step."
    Write-Host 'Windows Update brings a newer one; so does:  winget install Microsoft.OpenSSH.Preview'
}

function Show-Usage($script) {   # the comment at the top of the script
    foreach ($line in Get-Content $script) {
        if ($line -notmatch '^#') { break }
        Write-Host ($line -replace '^# ?', '')
    }
    exit 1
}

# The lines of machines.txt: name, address, system (linux, windows or macos), user.
function Get-Machines {
    if (-not (Test-Path $machinesFile)) { return }
    foreach ($line in Get-Content $machinesFile) {
        $fields = @(($line -replace '\s*#.*', '').Trim() -split '\s+')
        if ($fields.Count -lt 4) { continue }
        $system = $fields[2]
        if ($system -eq 'kubuntu') { $system = 'linux' }
        New-Object psobject -Property @{ Name = $fields[0]; Address = $fields[1]; System = $system; User = $fields[3] }
    }
}

function Save-User($name, $user) {   # puts the user name that worked in the machine's line of machines.txt
    $lines = foreach ($line in Get-Content $machinesFile) {
        $fields = @($line.Trim() -split '\s+')
        if ($line -notmatch '^\s*#' -and $fields.Count -ge 4 -and $fields[0] -eq $name) {
            '{0,-17} {1,-16} {2,-9} {3}' -f $fields[0], $fields[1], $fields[2], $user
        } else { $line }
    }
    [IO.File]::WriteAllText($machinesFile, (($lines -join "`n") + "`n"))
}

function Test-Reachable($address) {   # is anything answering on the SSH port of this address
    $client = New-Object Net.Sockets.TcpClient
    try {
        $attempt = $client.BeginConnect($address, 22, $null, $null)
        return ($attempt.AsyncWaitHandle.WaitOne(3000) -and $client.Connected)
    } catch { return $false } finally { $client.Close() }
}

# What to do on a machine that does not answer; README.md has the long version.
function Show-NotReachable($system) {
    Write-Host '    no answer on the SSH port. The machine is off or asleep, on another network, or SSH is off or firewalled.'
    switch ($system) {
        'linux' { Write-Host '    On it, run:  sudo apt install -y openssh-server   (and, with ufw on:  sudo ufw allow ssh)' }
        'macos' { Write-Host '    On it: System Settings > General > Sharing > Remote Login, on.  Or:  sudo systemsetup -setremotelogin on' }
        'windows' {
            Write-Host '    On it, in PowerShell as administrator, run:'
            Write-Host '      Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service sshd -StartupType Automatic'
        }
    }
    Write-Host '    More, and how to install without SSH: README.md, "Getting a machine ready".'
}

# ---- remembered passwords ----

function Get-PasswordTable {
    $table = @{}
    if (Test-Path $passwordFile) {
        foreach ($line in Get-Content $passwordFile) {
            $name, $value = $line -split ' ', 2
            if ($value) { $table[$name] = $value }
        }
    }
    $table
}

function Get-Remembered($name) {   # the machine's password, or '' when none is remembered
    $table = Get-PasswordTable
    if (-not $table.ContainsKey($name)) { return '' }
    try { return (New-Object Net.NetworkCredential('', (ConvertTo-SecureString $table[$name]))).Password } catch { return '' }
}

function Set-Remembered($name, $password) {
    $table = Get-PasswordTable
    $table[$name] = ConvertFrom-SecureString (ConvertTo-SecureString $password -AsPlainText -Force)
    Set-Content $passwordFile -Encoding ASCII -Value @($table.Keys | Sort-Object | ForEach-Object { "$_ $($table[$_])" })
}

function Clear-Remembered { Remove-Item $passwordFile -ErrorAction SilentlyContinue }

function Read-Password($prompt) {
    $typed = Read-Host -AsSecureString $prompt
    (New-Object Net.NetworkCredential('', $typed)).Password
}

# ---- connections ----

function Test-Login($target, [switch]$KeyOnly) {   # can ssh log in: with a key only, or with $env:MATRIX_PASSWORD too
    if ($KeyOnly) { & ssh @sshOptions -o BatchMode=yes $target exit 2>$null | Out-Null }
    else { & ssh @sshOptions $target exit 2>$null | Out-Null }
    $LASTEXITCODE -eq 0
}

# Connect-Machine MACHINE: returns Target (user@address), User and Password ('' when the login goes by SSH key
# and no password is remembered), or nothing when the login fails. Leaves the password where ssh will find it.
function Connect-Machine($machine) {
    $user = $machine.User
    if ($user -eq '-') { $user = $env:USERNAME }
    $target = "$user@$($machine.Address)"
    $password = Get-Remembered $machine.Name
    $env:MATRIX_PASSWORD = $password
    if (Test-Login $target -KeyOnly) { return @{ Target = $target; User = $user; Password = $password } }
    if ($password) {
        if (Test-Login $target) { return @{ Target = $target; User = $user; Password = $password } }
        Write-Host '    the remembered password no longer works'
    }
    $answer = Read-Host "    $($machine.Name): user name [$user]"
    if ($answer) { $user = $answer }
    $target = "$user@$($machine.Address)"
    $password = Read-Password "    $($machine.Name): password of $user"
    if (-not $password) { return }
    $env:MATRIX_PASSWORD = $password
    if (-not (Test-Login $target)) { return }
    Save-User $machine.Name $user
    Set-Remembered $machine.Name $password
    @{ Target = $target; User = $user; Password = $password }
}

function Invoke-Remote($target, $command) {   # runs a command on the machine, showing what it prints; true when it worked
    & ssh @sshOptions $target $command | Out-Host
    $LASTEXITCODE -eq 0
}

function Copy-Remote($target, $files, $destination) {   # copies files to the machine; true when it worked
    & scp @sshOptions -q @files "${target}:$destination" | Out-Host
    $LASTEXITCODE -eq 0
}

# The command line that runs a script of this project on a machine, with nothing copied there first.
# $script is its text; comment lines are left out to keep the line short.
function Get-WindowsCommand($script) {
    $text = (@($script -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    'powershell -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text))
}
function Get-UnixCommand($script, $arguments) {
    $text = ((@($script -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n") + "`n"
    'echo ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) + " | base64 --decode | bash -s -- $arguments"
}
