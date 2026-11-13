# DNSUpdater

Keeps a Dynu dynamic-DNS hostname pointed at this Mac and keeps a running
transcript of every IP address change. Replaces DynuUpdater and the old Dynu IP
Update Client.

- **Menu-bar app** (no Dock icon): current IP, last check, Update Now, Show IP Log…, Settings….
- **IP log window**: every check as `date time  IP  CHANGED from <old IP>` or `unchanged`, errors included. "Only changes and errors" is on by default.
- **Launch agent** `com.timmccoy.dnsupdater.agent` runs `DNSUpdater --update` every 5 minutes (changeable in Settings).
- Settings and history live in `~/Library/Application Support/DNSUpdater/` (`config.json`, `history.log`, `state.json`).
- First run takes the account settings and the old log from `DynuUpdater`.
- IPv4 only; Dynu detects the address from the request.

Build: `./build.sh` (universal, ad-hoc signed into `dist/`), `./build.sh --install` also installs to /Applications.
Modes: no argument = menu-bar app, `--update` = one headless update, `--install-agent` = write and load the launch agent.
