# Diagnosis log: from "my IP keeps jumping" to the firmware bug

How a cosmetic menubar-app symptom led to a confirmed GL-E5800 firmware
regression — and the two measurement traps that made it hard to see.

> **Anonymized:** real IP addresses replaced with RFC 5737 documentation
> ranges (203.0.113.x = tunnel exit, 198.51.100.x = roaming carrier IPs).

## Timeline

### Act 1 — The misleading symptom

A macOS menubar IP widget (MenuBar IP) "jumped" several times a day between
the expected tunnel exit (`203.0.113.10`, M1 Singapore) and local carrier
IPs (`198.51.100.20`, `198.51.100.21` — China Telecom Beijing; different IPs
in different travel cities).

First suspects, all eliminated by measurement:

| Hypothesis | Test | Verdict |
|---|---|---|
| App memory bug / stale cache | disk cache hunt, restart test | no cache on disk |
| One of the 8 probe services "poisoned" | 7 endpoints × 5 rounds from the same network | zero wrong answers |
| DNS poisoning | parallel DNS capture vs system resolver | clean |
| UPnP leaking the router's WAN address | binary has no UPnP/SSDP code; SSDP M-SEARCH unanswered | dead end |
| HTTP plaintext tampering (ip-api.com is the only HTTP service) | plausible! — real, but only a minor channel | confirmed but not the main cause |

### Act 2 — The truth probe that went blind

We ran a 1-second `curl https://api.ipify.org` loop as ground truth. It showed
**100% tunnel IP, 78/78** — the app must be lying, right?

Wrong. The decisive capture (2026-10-22 10:05:43–10:06:19):

- The 1-second CF probe loop logged **11 consecutive TIMEOUTs** — the tunnel
  was *actually down* for that window.
- Simultaneously, a probe against `ipwho.is` (not Cloudflare, not
  GFW-blocked) answered via the direct path and honestly reported
  `198.51.100.20` — the roaming carrier's IP.

**Lesson:** a probe that only works through the tunnel reports *nothing*
(timeout) during outages, not the direct IP. Sampling only from it makes the
egress look permanently tunnel-clean. Truth probes must be reachable both ways.

DNS side-evidence during a jitter window: a single `trackip.net` query id was
retransmitted 14 times in 22 s.

### Act 3 — QUIC: the app wasn't lying, it was racing

Even with the tunnel provably healthy (CF gate answering M1), the app's
`fetchIP()` kept returning Beijing carrier IPs at a suspiciously consistent
~0.32 s — while every manual curl to the same 7 service URLs returned the
tunnel IP.

`tcpdump` at the exact fetch timestamps showed a burst of **UDP/443 (QUIC)**
to `34.160.111.145` (ifconfig.me, Google Cloud) and a Cloudflare IP, ~0.3 s
before each wrong answer:

- The GFW blocks **TCP** to that GCP frontend, but passes **UDP/443**.
- PassWall2 routes TCP through the tunnel; **UDP/443 is not routed** and
  egresses directly.
- macOS `URLSession` uses HTTP/3 by default: QUIC-to-GCP direct (~0.32 s)
  beat TCP-to-Cloudflare via tunnel (~0.9 s) every single race.

The app displayed the winner of that race — the **direct** IP. In every travel
city, the first QUIC answer carries that city's carrier IP: the "IP follows
my trips" mystery solved.

**Lesson:** if an exit-IP tool "flaps" between VPN and local carrier while the
tunnel is fine, check for HTTP/3 before touching the proxy.

### Act 4 — The actual disease

With measurement noise removed, the remaining signal was a real, periodic WAN
outage: 40–60 s, new WAN IP every time, several times a day, worse in bursts.
That cadence matched GL.iNet forum reports exactly:

- ESM cause 36 network-initiated PDP deactivations (4.8.5),
- fixed in 4.10 beta2,
- **regressed in 4.10.0 stable**: control-plane desync, QCMAP tearing down the
  working backhaul every ~10–30 min. GL.iNet acknowledged 2026-09-11;
  fix pending as of 2026-10-22.

The PassWall2 "crashes" were downstream symptoms of the WAN dropouts.

## Tooling notes (for reproducing)

- Truth probe pair: `curl https://api.ipify.org` (tunnel-only) **and**
  `curl https://ipwho.is/` (works both ways), 1 Hz, logged with timestamps.
- QUIC correlation: `sudo tcpdump -i any -n -tt "udp port 443"`, then align
  packet epochs with the app's fetch logs.
- Firmware fingerprint: `grep -E "CallendCode|re-register" /etc/sys_log`
  on the router.
