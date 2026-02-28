# AnonManager v4.0

**Whonix-style Tor anonymity suite for Linux.**  
Routes all system traffic through Tor using an isolated network namespace. Every change is fully reversed when you disable or exit.

---

## How it works

```
Your App
   │
   ▼
iptables DNAT  ──────────────────────────────────────────┐
   │                                                      │
   │  DNS  → 10.200.1.1:5353  (Tor DNSPort)              │
   │  TCP  → 10.200.1.1:9040  (Tor TransPort)            │
   │                                                      │
   ▼                                                      │
Network Namespace "anonspace"                             │
   │                                                      │
   │  Tor process (runs AS tor user, INSIDE namespace)    │
   │  Binds to 10.200.1.1 on veth_tor interface          │
   │                                                      │
   ▼                                                      │
veth_host (10.200.1.2) → Host NAT → Physical NIC → Internet
```

Tor runs **inside** an isolated network namespace (Whonix-style).  
The killswitch drops all non-Tor host traffic — there is no fallback to clearnet.

---

## Supported systems

| Distro | Package manager | Firewall |
|---|---|---|
| Debian / Ubuntu / Kali / Parrot | apt | iptables or nftables |
| Arch / Manjaro / EndeavourOS | pacman | nftables preferred |
| RHEL / Fedora / AlmaLinux / Rocky | dnf | nftables (+ EPEL auto-enabled) |

---

## Install

```bash
# Clone
git clone https://github.com/johngichuki0254-ui/j.git anonmanager
cd anonmanager

# Install to system
sudo cp -r . /usr/local/lib/anonmanager
sudo cp anonmanager /usr/local/bin/anonmanager
sudo chmod +x /usr/local/bin/anonmanager

# Run
sudo anonmanager
```

---

## Usage

```bash
sudo anonmanager              # Interactive menu
sudo anonmanager --extreme    # Enable full isolation immediately
sudo anonmanager --partial    # Browser-only anonymity (apt/git still work)
sudo anonmanager --disable    # Restore system to normal
sudo anonmanager --status     # Live status dashboard
sudo anonmanager --verify     # 10-point anonymity verification
sudo anonmanager --newid      # Request new Tor exit identity
sudo anonmanager --logs       # View/tail logs
sudo anonmanager --restore    # Emergency restore (broken system recovery)
```

---

## Modes

### Extreme mode
- All TCP traffic redirected through Tor
- DNS locked to Tor (immutable resolv.conf)
- IPv6 fully disabled
- Firewall killswitch — non-Tor traffic is dropped
- MAC address randomized
- Kernel hardened (TCP timestamps off, pointer leaks blocked, etc.)
- Background watchdog monitors all components

**While active:** `apt`, `git`, `ssh`, `docker` networking will not work.

### Partial mode
- DNS through Tor
- Tor available via proxychains4
- System tools work normally

```bash
proxychains4 firefox     # Anonymous browsing
apt update               # Works normally
git clone ...            # Works normally
```

---

## What it protects against

| Threat | Protected |
|---|---|
| ISP seeing your browsing destinations | ✅ Yes |
| Websites seeing your real IP | ✅ Yes |
| DNS provider logging your queries | ✅ Yes |
| IPv6 leaks | ✅ Yes |
| WebRTC STUN/TURN leaks | ✅ Yes |
| DNS-over-HTTPS bypass attempts | ✅ Yes |
| MAC address tracking on local network | ✅ Yes |

## What it does NOT protect against

| Threat | Protected |
|---|---|
| Browser fingerprinting (canvas, fonts, WebGL) | ❌ No |
| Logging into personal accounts | ❌ No — you deanonymize yourself |
| ISP knowing you use Tor | ❌ No (use bridges for this) |
| Nation-state traffic correlation attacks | ❌ No |
| Compromised machine / malware | ❌ No |
| Application-level telemetry (Chrome, VS Code, etc.) | ❌ Partial |

**For stronger anonymity:** Use [Tails OS](https://tails.boum.org) or [Whonix](https://www.whonix.org).  
**For browser fingerprinting:** Use [Tor Browser](https://www.torproject.org).

---

## Files changed on your system

When active, AnonManager modifies:

| File/Setting | Change | Restored on disable |
|---|---|---|
| `/etc/resolv.conf` | nameserver 127.0.0.1 (immutable) | ✅ Yes |
| `/etc/tor/torrc` | Custom config binding to 10.200.1.1 | ✅ Yes |
| `iptables` / `nftables` | Killswitch rules + NAT | ✅ Yes |
| `ip netns` | Creates `anonspace` namespace | ✅ Yes |
| `sysctl` | TCP timestamps, ICMP, BPF hardening | ✅ Yes |
| `net.ipv6.*` | disable_ipv6=1 | ✅ Yes |
| MAC address | Randomized via NM or macchanger | ✅ Yes |

---

## Architecture deep dive

```
/usr/local/lib/anonmanager/
├── anonmanager          # Entry point (thin wrapper)
├── core/
│   ├── init.sh          # Root check, lock, traps, globals, logging
│   ├── compat.sh        # Distro/firewall/pkg-manager detection
│   └── state.sh         # Validated atomic state persistence
├── system/
│   ├── packages.sh      # apt/pacman/dnf abstraction
│   ├── backup.sh        # Atomic snapshots + emergency restore
│   ├── hardening.sh     # Kernel sysctl hardening
│   └── monitor.sh       # Background watchdog
├── network/
│   ├── namespace.sh     # veth pair + namespace lifecycle
│   ├── firewall.sh      # iptables + nftables dual-backend killswitch
│   ├── dns.sh           # Symlink-safe DNS locking
│   ├── ipv6.sh          # IPv6 disable/restore
│   └── mac.sh           # MAC randomization
├── tor/
│   ├── configure.sh     # torrc generator (binds to NS_TOR_IP)
│   ├── supervisor.sh    # In-namespace Tor process manager
│   └── verify.sh        # Circuit verification + 10-point check
├── ui/
│   ├── banner.sh        # Status dashboard, HUD, warnings, help
│   ├── progress.sh      # Pipeline renderer, spinner, bootstrap bar
│   ├── log_viewer.sh    # Log tail, backend transparency report
│   └── menu.sh          # dialog/whiptail/text menu
├── modes/
│   ├── extreme.sh       # Full isolation orchestrator
│   ├── partial.sh       # Browser-only orchestrator
│   └── disable.sh       # Clean teardown orchestrator
└── tests/
    └── run_tests.sh     # 83 unit tests (no root required)
```

---

## Logs

```bash
tail -f /var/log/anonmanager.log          # All activity
tail -f /var/log/anonmanager-security.log # Security events only

sudo anonmanager --logs   # Colored viewer with live tail option
```

---

## Tests

```bash
bash tests/run_tests.sh
# Runs 83 tests covering: state machine, backup integrity,
# distro detection, package resolution, lock mechanism,
# argument parsing, syntax validation (no root required)
```

---

## Emergency recovery

If something goes wrong and your network is broken:

```bash
sudo anonmanager --restore
```

This will flush all firewall rules, destroy the namespace, restore DNS from backup, and restart NetworkManager — regardless of the current state.

If `anonmanager` itself is broken, manual recovery:

```bash
# Flush firewall
sudo iptables -F; sudo iptables -X; sudo iptables -t nat -F; sudo iptables -t nat -X
sudo iptables -P INPUT ACCEPT; sudo iptables -P OUTPUT ACCEPT; sudo iptables -P FORWARD ACCEPT

# Destroy namespace
sudo ip netns delete anonspace 2>/dev/null

# Restore DNS
sudo chattr -i /etc/resolv.conf
sudo systemctl restart systemd-resolved || sudo systemctl restart NetworkManager

# Re-enable IPv6
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0
```

---

## Security notes

- The Tor control port cookie is never exposed in process arguments (`ps aux` safe)
- State file is validated against a strict key/value whitelist — injection impossible
- Backups are written atomically (tmp → rename) — partial backups are detected and rejected
- `resolv.conf` backup is symlink-aware — correctly handles `systemd-resolved` setups
- Every `sysctl` write uses `timeout 2` — nothing can hang the script
- `set -euo pipefail` is active from line 1 — failed commands abort, not silently continue

---

## Limitations

- Not a substitute for Tails OS or Whonix
- Does not protect against browser fingerprinting
- Compatible with Tor Browser for best protection
- Incompatible with active VPNs
- Tor exit nodes can see unencrypted (HTTP) traffic — use HTTPS
