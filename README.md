# DNSUpdater

A small Mac app that keeps your Dynu dynamic-DNS hostname pointed at this Mac,
and keeps a running log of every change to your IP address and to ExpressVPN.
It replaces DynuUpdater and Dynu's own IP Update Client.

Version 1.3.1 · macOS 12 or later · Intel and Apple silicon

## What it does

* **Checks every 5 minutes** (you can change this in Settings) and tells Dynu
  your current address. Dynu sees the address the request comes from, so
  nothing else is needed.
* **Logs only what changed.** The IP log shows a line when your address
  changes, when ExpressVPN connects, disconnects or changes location, when
  ExpressVPN itself is updated, and when an update fails. A check where nothing
  changed adds nothing.
* **Checks right away** when the network changes (a VPN coming up or going
  down), without waiting for the next 5 minutes.

Example log:

    2026-11-13 07:58:30  VPN connected: Mexico  (CHANGED)
    2026-11-13 08:26:26  185.238.231.86  CHANGED from 185.238.231.105
    2026-11-13 08:28:55  VPN disconnected  (CHANGED)

## Using it

DNSUpdater has a Dock icon and a menu-bar icon. The menu-bar menu shows the
current IP and the last check, and has:

* **Update Now**
* **Show IP Log…**
* **Settings…** — Dynu username, password, hostname (blank = every hostname on
  the account) and how often to check (1, 2, 5, 10, 15, 30 or 60 minutes).
  Saving also reloads the background updater.
* **Quit DNSUpdater**

Closing the log window does not quit the app; click the Dock icon to bring it
back.

### The log window

* **Changes and errors only** is on by default.
* The window opens where you last left it, at the size you left it, and
  refreshes every 3 seconds. The first time it opens centred on the screen
  ExpressVPN's window is on.
* **The log is emptied every time the app starts**, including at login. The
  background 5-minute check never clears it.
* To open it on a particular desktop, go to that desktop and right-click the
  Dock icon → Options → Assign To → This Desktop.

## How it works

* The app itself starts at login (it is a login item). The checks are done by a
  separate launch agent, `com.timmccoy.dnsupdater.agent`, which runs
  `DNSUpdater --update` on a timer, so updates continue whether or not the app
  is open.
* ExpressVPN has no command-line tool here, so its state is read from the
  system: a tunnel (`utun`) interface with an IPv4 address means a VPN is up,
  and the location is the first entry in ExpressVPN's own recent-locations
  list. That is the last location you picked, so a location picked but not
  connected can show. Any other VPN would also count as connected.
* The password is stored as an MD5 hash, which is what Dynu's update API
  accepts. IPv4 only.

Files are in `~/Library/Application Support/DNSUpdater/`:

    config.json    username, password hash, hostname, interval (readable only by you)
    history.log    the IP log
    state.json     last IP, last check, last VPN state
    agent.log      output of the background updater

## Building

    ./build.sh              universal app (Intel + Apple silicon), ad-hoc signed, into dist/
    ./build.sh --install    also installs to /Applications and relaunches it

Modes of the one program:

    DNSUpdater                  the menu-bar app
    DNSUpdater --update         one headless update, as the launch agent runs it
    DNSUpdater --install-agent  write and load the launch agent

The source is `main.swift`; the icon is `AppIcon.icns`, made from
`DNSUpdaterIcon.png`.

© 2026 Tim McCoy. A personal utility, not published.
