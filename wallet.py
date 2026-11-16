#!/usr/bin/python3
"""Keeps the passwords of the machines in the KDE wallet of this machine, for common.sh.

  wallet.py get NAME      prints the password kept for machine NAME; fails when there is none
  wallet.py set NAME      keeps the password read from standard input
  wallet.py forget NAME   drops it

They are in the wallet's folder "matrix-screensaver" (KWalletManager shows them), encrypted with the rest of
the wallet. Fails, keeping nothing, where there is no KDE wallet; the scripts then ask every time.
"""
import sys

FOLDER = APP = "matrix-screensaver"


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("get", "set", "forget"):
        sys.exit(__doc__)
    action, name = sys.argv[1:]
    import dbus
    bus = dbus.SessionBus()
    wallet = None
    for version in ("6", "5"):
        try:
            wallet = dbus.Interface(bus.get_object("org.kde.kwalletd" + version, "/modules/kwalletd" + version), "org.kde.KWallet")
            handle = wallet.open(wallet.networkWallet(), dbus.Int64(0), APP, timeout=120)  # may ask to unlock the wallet
            break
        except dbus.DBusException:
            wallet = None
    if wallet is None or handle < 0:
        sys.exit(1)
    if action == "get":
        if not wallet.hasEntry(handle, FOLDER, name, APP):
            sys.exit(1)
        sys.stdout.write(wallet.readPassword(handle, FOLDER, name, APP) + "\n")
    elif action == "set":
        if not wallet.hasFolder(handle, FOLDER, APP):
            wallet.createFolder(handle, FOLDER, APP)
        if wallet.writePassword(handle, FOLDER, name, sys.stdin.readline().rstrip("\n"), APP) != 0:
            sys.exit(1)
    else:
        wallet.removeEntry(handle, FOLDER, name, APP)


try:
    main()
except Exception as error:  # no D-Bus, no wallet: the caller asks for the password instead
    sys.exit("wallet: %s" % error)
