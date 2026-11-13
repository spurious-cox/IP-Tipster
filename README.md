# IP Tipster

Dynu Systems Inc. provides a free dynamic DNS service and update client.
IP Tipster is a small Mac app that keeps your hostname on that service pointed
at this Mac, and keeps a running log of every change to your IP address and to
your VPN.

Version 1.6.0 · macOS 12 or later · Intel and Apple silicon

## Download

Get the latest `IP-Tipster-<version>.dmg` from the
[Releases page](https://github.com/spurious-cox/IP-Tipster/releases/latest), open
it, and drag **IP Tipster** to Applications. It is signed and notarized by Apple.

## What it does

* **Checks every 5 minutes** (you can change this in Settings) and tells the
  service your current address. It sees the address the request comes from, so
  nothing else is needed.
* **Logs only what changed.** The IP log shows a line when your address
  changes, when a VPN connects or disconnects (with location and update
  details as the VPN service may provide), and when an update fails. A check
  where nothing changed adds nothing.
* **Checks right away** when the network changes (a VPN coming up or going
  down), without waiting for the next 5 minutes.

Example log:

    2026-11-13 07:58:30  CHANGED VPN connected: Mexico
    2026-11-13 08:26:26  CHANGED from 185.238.231.105 to 185.238.231.86
    2026-11-13 08:27:10  CHANGED IPv6 from 2001:db8::1 to 2001:db8::2
    2026-11-13 08:28:55  CHANGED VPN disconnected

## Using it

IP Tipster has a Dock icon and a menu-bar icon. The menu-bar menu shows the
current IP and the last check, and has:

* **Update Now**
* **Show IP Log…**
* **Settings…** — account username, password, hostname (blank = every hostname on
  the account), how often to check (1, 2, 5, 10, 15, 30 or 60 minutes), whether
  the log window opens at startup, and whether there is a Dock icon (off = menu
  bar only). Saving also reloads the background updater.
* **Quit IP Tipster**

The log window has a **Hide** button; closing or hiding it does not quit the
app. Bring it back from the Dock icon or **Show IP Log…** in the menu bar.

### The log window

* **Changes and errors only** is on by default. Location changes show in green.
* The window opens where you last left it, at the size you left it, and
  refreshes every 3 seconds. The first time it opens, it is centered on the
  screen.
* **Entries older than 7 days are removed automatically**, when the app starts
  and whenever a new entry is added.
* To open it on a particular desktop, go to that desktop and right-click the
  Dock icon → Options → Assign To → This Desktop.

## How it works

* The app itself starts at login (it is a login item). The checks are done by a
  separate launch agent, `com.timmccoy.iptipster.agent`, which runs
  `IPTipster --update` on a timer, so updates continue whether or not the app
  is open.
* VPN state is read from the system: a tunnel (`utun`) interface with an IPv4
  address means a VPN is up, whichever VPN service it is. Location and update
  details are included only when the VPN service provides them, and a location
  picked but not yet connected may show.
* The password is stored as an MD5 hash, which is what the service's update
  API accepts.
* IPv6 is supported. If this Mac has a public IPv6 address, it is found with an
  IPv6-only lookup (`api6.ipify.org`, a free third-party echo service), sent with
  the update, and logged as `CHANGED IPv6 from <old> to <new>`. With no IPv6
  connection nothing is looked up and no IPv6 lines appear.

Files are in `~/Library/Application Support/IP Tipster/`:

    config.json    username, password hash, hostname, interval (readable only by you)
    history.log    the IP log
    state.json     last IP, last check, last VPN state
    agent.log      output of the background updater

## Building

    ./build.sh              universal app (Intel + Apple silicon), ad-hoc signed, into dist/
    ./build.sh --install    also installs to /Applications and relaunches it
    ./release.sh            Developer ID sign, make the DMG, notarize and staple it

Modes of the one program:

    IPTipster                    the menu-bar app
    IPTipster --update           one headless update, as the launch agent runs it
    IPTipster --install-agent    write and load the launch agent

The source is `main.swift`; the icon is `AppIcon.icns`, made from
`IPTipsterIcon.png`.

© 2026 Tim McCoy. A personal utility, not published.
Not affiliated with Dynu Systems Inc.
