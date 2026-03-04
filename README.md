# AnonManager v4.0

**Whonix-style Tor anonymity suite for Linux.**  
Routes all system traffic through Tor using an isolated network namespace. Every change is fully reversed on disable or exit.

---

## Requirements

- Linux (Debian/Ubuntu/Kali, Arch/Manjaro, RHEL/Fedora/AlmaLinux)
- `bash` 4.4+
- Root / sudo
- Internet connection (Tor is installed automatically if missing)

---

## Install

```bash
git clone https://github.com/johngichuki0254-ui/j.git anonmanager
cd anonmanager
sudo anonmanager
```

That's it. Dependencies (tor, iptables, curl, xxd, nc) are installed automatically on first run if missing.

---

## Run

```bash
sudo anonmanager                 # Interactive menu (recommended)
sudo anonmanager --extreme       # Enable full isolation directly
sudo anonmanager --partial       # Browser-only anonymity
sudo anonmanager --disable       # Restore system to normal
sudo anonmanager --status        # Live status dashboard
sudo anonmanager --verify        # 12-point anonymity check
sudo anonmanager --newid         # Get new Tor exit identity
sudo anonmanager --logs          # View/tail logs
sudo anonmanager --restore       # Emergency recovery
```

---

## Menu options

Once in the interactive menu:

| Key | Action |
|-----|--------|
| `1` | Enable Extreme Anonymity — all traffic through Tor |
| `2` | Enable Partial Anonymity — browser/proxychains only |
| `3` | Disable Anonymity — restore system |
| `4` | Identity & Location — choose country and OS persona |
| `5` | Bridges — obfs4/snowflake for censored networks |
| `6` | Verify Anonymity — 12-point check |
| `7` | New Identity / Auto-rotate — NEWNYM + rotation schedule |
| `8` | DNS Leak Test — 3-method active check |
| `a` | Session History — past anonymity sessions |
| `b` | Locale Check — 8-point identity consistency |
| `c` | Backend Report — what changed on your system |
| `d` | View Logs |
| `9` | Emergency Restore |

---

## Modes

### Extreme (full isolation)
- All TCP routed through Tor via network namespace
- DNS locked to Tor DNSPort — no clearnet DNS possible
- Killswitch drops all non-Tor traffic
- IPv6 fully disabled
- MAC address randomized (vendor-aware: Apple, Samsung, Dell, Lenovo, or random)
- Kernel hardened (TCP timestamps, pointer leaks, ICMP)
- Background watchdog monitors all components and alerts on failure
- Session logged (exit IP, duration, DNS leak result)
- Auto-rotate Tor identity on configurable interval (5–480 min)
- Locale consistency checked against chosen identity

**While active:** `apt`, `git`, `ssh`, `docker` networking will not work — all traffic goes through Tor or is dropped.

### Partial
- DNS through Tor
- Tor available via `proxychains4`
- System tools work normally

```bash
proxychains4 firefox     # Anonymous browsing
apt update               # Works normally
```

---

## Identity system

Choose a country exit node and OS persona before enabling:

```
Menu → 4 (Identity & Location)
```

- **Location:** US state, Canadian province, European country, or 80+ others
- **Persona:** macOS/Safari, Windows/Chrome, Linux/Firefox, Android, iOS
- Sets Tor `ExitNodes`, hostname, curl User-Agent, and locale

---

## Bridges (censored networks)

If Tor is blocked in your country:

```
Menu → 5 (Bridges)
```

- Supports obfs4, snowflake, meek
- Paste bridge lines from [bridges.torproject.org](https://bridges.torproject.org)
- Built-in public bridges available as fallback

---

## DNS leak test

Three independent methods run on demand or automatically at session start:

- **Method A** — bash.ws API: triggers DNS through Tor, checks resolver ASNs. Flags any resolver owned by a consumer ISP (not a Tor exit).
- **Method B** — local config: checks `/etc/resolv.conf`, systemd-resolved, nsswitch.conf
- **Method C** — kernel sockets: reads `/proc/net/udp` and `/proc/net/udp6` for port-53 sockets outside the namespace

---

## Tests

No root required:

```bash
bash tests/run_tests.sh
```

Expected output: **153 passed, 0 failed**

Covers: state machine, backup integrity, distro detection, package resolution, lock mechanism, argument parsing, syntax validation, all five feature modules, and explicit regression tests for every bug fixed in the v4.0 review pass.

---

## Emergency recovery

If your network is broken after a crash:

```bash
sudo anonmanager --restore
```

Manual fallback if the script itself is broken:

```bash
sudo iptables -F && sudo iptables -t nat -F
sudo iptables -P INPUT ACCEPT && sudo iptables -P OUTPUT ACCEPT && sudo iptables -P FORWARD ACCEPT
sudo ip netns delete anonspace 2>/dev/null || true
sudo chattr -i /etc/resolv.conf
sudo systemctl restart NetworkManager
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
```

---

## Logs

```bash
tail -f /var/log/anonmanager.log           # All activity
tail -f /var/log/anonmanager-security.log  # Security events
```

---

## What it protects against

| Threat | Status |
|--------|--------|
| ISP seeing browsing destinations | ✅ |
| Websites seeing your real IP | ✅ |
| DNS provider logging queries | ✅ |
| IPv6 leaks | ✅ |
| DNS leaks (ISP resolver) | ✅ |
| MAC address tracking on LAN | ✅ |
| Browser fingerprinting | ❌ — use Tor Browser |
| Logging into personal accounts | ❌ — you deanonymize yourself |
| Nation-state traffic correlation | ❌ |

For stronger anonymity use [Tails OS](https://tails.boum.org) or [Whonix](https://www.whonix.org).

---

## Limitations

- Requires root
- Incompatible with active VPNs
- Does not protect against browser fingerprinting
- Tor exit nodes can see unencrypted HTTP traffic — use HTTPS
