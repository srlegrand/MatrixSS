# Matrix screensaver

A 3D "digital rain" screensaver that starts after 5 idle minutes, and scripts that install it on every
computer on your network from one of them, and start it on all of them at once.

| | Installs on | Deploys from |
|---|---|---|
| **Linux** | Kubuntu: KDE Plasma 5 or 6, X11 or Wayland, on Ubuntu or Debian | any Linux with bash and ssh |
| **Windows** | Windows 10 and 11, 64-bit | Windows 10 and 11 |
| **macOS** | a recent macOS, with Apple's command line tools | any Mac |

**How far each part has been tried.** This was developed on Kubuntu 24.04 (Plasma 5, X11), deploying from
Linux. Not run yet, because they were written without such a machine at hand: everything on macOS (the
screensaver, its installer, deploying from a Mac) and deploying from Windows (`deploy.cmd`, `test.cmd`).
Expect to fix something the first time you use those; [When something goes wrong](#when-something-goes-wrong)
says where to look.

## Quick start

1. **Get this folder onto one computer**, the one you will deploy from. Nothing needs building: the Linux
   and Windows programs are in the folder, and each Mac compiles its own.
2. **Switch SSH on on the other computers.** One command or one switch each; see
   [Getting a machine ready](#getting-a-machine-ready). Computers where that is not possible can be done
   [by hand](#installing-by-hand-without-ssh).
3. **List the other computers** in `machines.txt`. Copy `machines.example.txt` to `machines.txt` and edit
   it; the file explains its four columns. On Linux and macOS, `./find.sh` looks on your network and prints
   the lines for you:

       ./find.sh >> machines.txt

   Then open `machines.txt` and check the *system* and *user* columns.
4. **Deploy.**

   | From | Run |
   |---|---|
   | Linux, macOS | `./deploy.sh` |
   | Windows | `deploy.cmd` (in a Command Prompt or PowerShell window opened in this folder) |

   It installs on the computer you are at, then on each one in `machines.txt`. The first time it asks for
   each computer's user name and password, and remembers them. A computer that does not answer is skipped,
   with a line saying what to do on it; run deploy again later and it picks up the ones that were missed.
5. **See it.** `./test.sh` (or `test.cmd`) starts the screensaver on every computer at the same moment.

## The commands

On Windows, read `deploy.cmd` for `./deploy.sh`, `test.cmd` for `./test.sh`, and `-remove`, `-forget` for
`--remove`, `--forget`.

| Command | What it does |
|---|---|
| `./deploy.sh` | install or update on this computer and all in `machines.txt` |
| `./deploy.sh nuc office-pc` | only on these. This computer goes by its own name (`hostname -s`; on Windows, the computer name) |
| `./deploy.sh --remove` | uninstall everywhere, putting back the settings it changed. Names work here too |
| `./deploy.sh --forget` | drop the remembered passwords |
| `./test.sh` | start the screensaver everywhere now; it stays until someone touches that computer |
| `./test.sh 15` | show it for 15 seconds, then close it |
| `./test.sh 15 nuc office-pc` | only on these. This computer goes by its own name here too |
| `./find.sh` | list computers on your network that have SSH on (Linux and macOS only) |

`test` needs the screensaver installed and someone logged in at the screen of each computer.

## Getting a machine ready

Deploying needs three things from each computer: it is **on and awake**, it **answers SSH** from the computer
you deploy from, and you know an **account and its password** on it.

### Linux (Kubuntu)

    sudo apt install -y openssh-server

- **Firewall.** Ubuntu's firewall (ufw) is off unless someone switched it on. If it is on:
  `sudo ufw allow ssh`.
- **Account.** It must be allowed to use `sudo`, because the screensaver is installed for all users of the
  computer. The first account created on Ubuntu is.

### Windows 10 and 11

In PowerShell **as administrator** (right-click Start > Terminal (Admin) or Windows PowerShell (Admin)):

    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    Start-Service sshd
    Set-Service sshd -StartupType Automatic

- **Firewall.** Installing the SSH server adds a firewall rule, but on some versions only for networks marked
  *Private*, and Windows marks new networks *Public*. If the computer still does not answer, either mark the
  network as private (Settings > Network & internet > your connection > Private network), or open the port
  on every kind of network:

      New-NetFirewallRule -Name matrix-ssh -DisplayName "SSH" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any

  Antivirus suites that bring their own firewall (Norton, Bitdefender, Kaspersky, ...) need port 22 allowed
  in their own settings.
- **Account.** The user name is the name of the folder under `C:\Users`, not an e-mail address. With a
  Microsoft account the password is the Microsoft account's password; a PIN, a fingerprint or a face do not
  work over SSH. An account with no password cannot log in over SSH at all: give it one (Settings >
  Accounts > Sign-in options > Password), or install [by hand](#installing-by-hand-without-ssh).
- The screensaver is installed for that one account. Other accounts on the same computer need their own
  line in `machines.txt` (same address, different name and user).

### macOS

System Settings > General > Sharing > **Remote Login**, on, with your account allowed. Or in Terminal:

    sudo systemsetup -setremotelogin on

- **Firewall.** The macOS firewall lets Remote Login through by itself, unless *Block all incoming
  connections* is ticked in System Settings > Network > Firewall > Options.
- **Compiler.** The rain is compiled on the Mac, with Apple's command line tools. Once per Mac, in Terminal:

      xcode-select --install

  and confirm in the window that opens (a download of a few minutes). Deploy says so when they are missing.
- **Account.** Any account; no administrator rights needed. It is installed for that one account.

### The computer you deploy from

| | Needs |
|---|---|
| Linux | `ssh` and `nc`, which Ubuntu has. To have passwords remembered: KDE (its wallet is used), or on other desktops `sudo apt install libsecret-tools` |
| macOS | nothing; passwords go in your login keychain |
| Windows | nothing on an up-to-date Windows 10 or 11. If `ssh` is missing: `Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0` as administrator |

## Networks

- **Same network.** All of this assumes the computers can reach each other directly: same router, cable
  or Wi-Fi. That is the case at home and in most small offices.
- **Guest Wi-Fi does not work.** Guest networks, and Wi-Fi with "client isolation" or "AP isolation"
  switched on, stop computers from seeing each other on purpose. Use the main network, or switch isolation
  off in the router.
- **Other networks, VPNs.** A computer on another network (another site, a VLAN, a VPN such as Tailscale
  or WireGuard) works as long as its address can be reached from the one you deploy from: put the address
  or name it has on that network in `machines.txt`. `find.sh` only looks at the network you are on, so add
  such computers by hand.
- **Addresses change.** Routers hand out addresses and may hand out a different one next week, and then a
  computer "does not answer". Either reserve a fixed address for it in the router (often called *DHCP
  reservation* or *static lease*), or put its name in `machines.txt` instead of the number. `name.local`
  works for Macs and most Linux computers, and many routers know every computer by a name of their own
  (`name.lan`, `name.home`). Check with `ssh user@name` first.
- **Asleep is the same as off.** A sleeping computer does not answer. Wake it, deploy, let it sleep again.
- **Not port 22.** If a computer's SSH listens on another port, give it an entry in `~/.ssh/config`
  (`Host`, `HostName`, `Port`) and use that `Host` name as the address in `machines.txt`.

To check one computer by hand, from the one you deploy from:

    ssh user@address

If that logs in, deploy will too. If it says *connection refused*, SSH is not running there; if it hangs
and times out, a firewall or the network is in the way, or the address is wrong.

## Installing by hand, without SSH

For a computer where SSH cannot be switched on, or that you cannot reach: copy the files to it (USB stick,
shared folder, e-mail) and run the installer there. The result is the same as with deploy.

| System | Copy these | Then run |
|---|---|---|
| Linux | `install.sh`, `matrix-rain` | `sudo bash install.sh` |
| Windows | `install.cmd`, `install.ps1`, `Matrix.scr` | double-click `install.cmd` |
| macOS | `install-macos.sh`, `matrix-rain.c`, `glyphs.h` | `bash install-macos.sh` |

To uninstall: `sudo bash install.sh --remove`, `install.cmd -Remove` (from a Command Prompt), or
`bash install-macos.sh --remove`.

On Windows, files that came from the internet or by e-mail are marked as unsafe and may be stopped with a
warning. Before unpacking a downloaded zip: right-click it > Properties > Unblock.

## Remembered logins

The first deploy or test asks for each computer's user name and password. After that:

- the **user name** is in `machines.txt`;
- the **password** is in the password store of the computer you deploy from: the login keychain on macOS,
  the KDE wallet or the desktop keyring on Linux, and on Windows a file only your Windows account can
  decrypt (`%LOCALAPPDATA%\MatrixScreensaver\passwords.txt`). It is never in this folder.

A password that has changed is asked for again. `./deploy.sh --forget` drops them all. Without a password
store (Linux with neither KDE nor `secret-tool`), everything works but asks every time.

If you would rather not have passwords stored: give each computer your SSH key
(`ssh-copy-id user@address`, on Linux and macOS) and logging in needs none. Linux computers still need the
password for `sudo`, which is asked for and, where possible, remembered.

## What it does to each computer

All of it is undone by `--remove`.

**Linux.** Installs the packages `xscreensaver`, `swayidle`, `cmatrix` and a few helpers, puts the rain in
`/usr/local/bin`, and starts a small session script at every user's login. On X11 the rain runs under
xscreensaver; on Wayland a watcher starts it full-screen. KDE's own idle lock is switched off and the
screensaver locks instead (only for users who had the lock on), and on mains power, screen-off and sleep
that would come within 10 minutes of the screensaver are moved to 30 minutes after it. On a computer that
is not x86-64, or where the 3D rain cannot start, a simpler stand-in is used.

**Windows.** Puts `Matrix.scr` in `%LOCALAPPDATA%\MatrixScreensaver` and sets it as the screen saver of
that account, after 5 minutes. On mains power, screen-off and sleep that would come within 10 minutes are
moved to 30 minutes. No administrator rights are used.

**macOS.** Compiles the rain into `~/Library/Application Support/MatrixScreensaver` and adds a login item
(a LaunchAgent, `local.matrix-screensaver`) that starts it full-screen after 5 idle minutes and closes it
on the first key press or mouse movement. It does not appear in System Settings > Screen Saver, and leaves
those settings alone: set the macOS screen saver to start later than 5 minutes, or never, so the two do not
take turns. It holds off while a video or a call keeps the screen awake. No administrator rights are used.

To change the 5 minutes, change `IDLE_MIN` at the top of `install.sh` and `install-macos.sh` and
`$IdleMinutes` in `install.ps1`, and deploy again.

## When something goes wrong

| What you see | What it means, and what to do |
|---|---|
| `no answer on the SSH port` | Off, asleep, wrong address, other network, SSH off, or firewalled: [Getting a machine ready](#getting-a-machine-ready) and [Networks](#networks). Try `ssh user@address` by hand |
| `could not log in` | Wrong user name or password. On Windows: the folder name under `C:\Users`, and the account's password, not its PIN. To see what SSH itself says, try `ssh user@address` by hand. If that says `REMOTE HOST IDENTIFICATION HAS CHANGED`, the address now belongs to a different computer, or that one was reinstalled; if that is expected: `ssh-keygen -R address` |
| `sudo did not take it` | The account may not use `sudo` on that Linux computer. Use one that may |
| `Apple's command line tools are missing` | On that Mac: `xcode-select --install`, then deploy again |
| It asks for passwords on every run | No password store on the computer you deploy from: [Remembered logins](#remembered-logins) |
| Windows: it asks for the password several times per computer | An old `ssh` on the Windows you deploy from. Run Windows Update, or `winget install Microsoft.OpenSSH.Preview` |
| test: `not installed` | Deploy to that computer first |
| test: `nobody is logged in`, or `it did not come up` | Someone must be logged in at that computer's screen, as the user in `machines.txt` |
| Windows: screensaver installed, never starts | A policy from an employer or school can fix the screen saver. Check Settings > Personalisation > Lock screen > Screen saver |
| macOS: the screen stays black, or nothing comes up | Run `~/Library/Application\ Support/MatrixScreensaver/matrix-rain --fullscreen --seconds 10` in Terminal on that Mac and read what it prints |

## The files

| | |
|---|---|
| `deploy.sh`, `test.sh`, `find.sh`, `common.sh`, `wallet.py` | deploying from Linux and macOS |
| `deploy.cmd`, `test.cmd`, `deploy.ps1`, `test.ps1`, `common.ps1` | deploying from Windows |
| `install.sh` | the installer that runs on a Linux computer |
| `install.ps1`, `install.cmd` | the installer that runs on a Windows computer |
| `install-macos.sh` | the installer that runs on a Mac |
| `show-linux.sh`, `show-macos.sh`, `show-windows.ps1` | what `test` runs on each computer |
| `matrix-rain.c`, `glyphs.h` | the rain itself: one source for all three systems |
| `matrix-rain`, `Matrix.scr` | the rain, built for Linux (x86-64) and Windows (64-bit) |
| `build.sh` | rebuilds those two, on Linux, after a change to `matrix-rain.c` |
| `gen_glyphs.py` | redraws `glyphs.h`; only for changing the font or the characters |
| `machines.example.txt` | the pattern for your `machines.txt` |

After changing `matrix-rain.c`: `./build.sh` on Linux (it lists the packages it needs), then deploy. Macs
compile the changed source themselves when you deploy to them.

## License

MIT; see `LICENSE`. The characters in `glyphs.h` are drawn from Noto Sans Mono CJK JP, a font under the
SIL Open Font License.
