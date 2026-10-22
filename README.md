# Mudi 7 (GL-E5800) WAN Dropout Field Guide + PassWall2 Self-Heal

A field report and self-healing watchdog for the **periodic WAN dropouts** on the
GL.iNet GL-E5800 (Mudi 7) — the bug family that silently kills your PassWall2
tunnel several times a day while roaming.

> 中文摘要见文末。TL;DR: Mudi 7 的 WAN 每 10–30 分钟掉线一次是**固件已知问题**
> (4.10.0 正式版为回退复发), 不是你的节点/运营商的锅。本仓库提供一个零休眠
> 暴力自愈脚本 + 完整的排障方法论(含"QUIC 绕过隧道让 IP 检测软件撒谎"这个坑)。

---

## 1. Symptoms (the fingerprint)

If your Mudi 7 matches most of these, you have this bug:

- WAN drops **every 10–30 minutes** (bursts 2–4 min apart during bad periods),
  each drop lasts **40–60 seconds**.
- Every drop assigns a **new WAN IP**; all TCP/VPN/proxy sessions die.
- `/etc/sys_log` shows `CallendCode=36` (network-initiated PDP deactivation,
  ESM cause 36) and/or forced re-registration.
- PassWall2 "falls over" at the same cadence — proxy dead for ~1 minute,
  then comes back by itself (or not, until restarted).
- Frequency gets worse on **roaming SIMs**.

## 2. Root cause (as confirmed by GL.iNet staff)

Firmware timeline, pieced together from the official forum
([thread 1](https://forum.gl-inet.com/t/gl-e5800-mudi-7-multiple-cellular-issues/70393),
[thread 2](https://forum.gl-inet.com/t/mudi-7-gl-e5800-1-3-minute-recovery-after-signal-loss-failed-redial-with-callendcode-202/71413)):

| Firmware | Status |
|---|---|
| 4.8.5 | Has the bug: ESM cause 36 deactivations every 10–30 min |
| 4.10 beta2 | Bug **fixed** (confirmed by reporter) |
| **4.10.0 stable (2026-09-01, latest as of 2026-10)** | **Regression**: dozens of WAN dropouts/day, same ~10–30 min cadence; control-plane desync (CEREG falsely reports unregistered, QCMAP tears down the *working* backhaul). GL.iNet acknowledged 2026-09-11, fix promised "in the next version" — **not yet released** |

Related amplifiers (also confirmed on the forum):

- **APN IP type `IPV4V6` while roaming** → the visited network grants no IPv6,
  the connection manager re-dials in a loop (~80 s cycle) and tears down the
  working IPv4 session each time. **Fix: set APN IP type to IPv4-only.**
- **Manual MTU (e.g. 1360)** kills sessions under load. Keep the default.
- **5G NSA SCG handover** failures drop the link for 1–3 min
  (`CallendCode=202`). Forcing **4G-only mode** is reported rock solid
  (at the cost of speed).

## 3. The self-heal watchdog: `passwall2-heal.sh`

Until the firmware fix ships, this script keeps PassWall2 alive. It was written
after diagnosing why naive restart loops **amplified** outages instead of
healing them.

### Design principles

1. **Probe explicitly through the proxy** — `curl -x socks5h://127.0.0.1:$PORT`.
   A bare probe tests your *direct* line and produces false negatives during
   exactly the moments you care about (and a false negative triggers a restart
   storm — how the v1 script turned 1-minute blips into 8-round disasters).
2. **WAN gate** — when the modem itself is unregistered (WAN dead), restarting
   the proxy is useless *and* harmful (every restart opens a direct-egress
   window). Wait for WAN instead, up to 30 min, without burning retry rounds.
3. **Wait for the SOCKS port to actually listen** before probing — no blind
   `sleep` guesses.
4. **Zero-sleep aggressive retry** — on probe failure, restart immediately;
   round pacing comes naturally from the port-readiness wait (~1 round/min).
   Never gives up.
5. Lock file + syslog tags so you can watch it: `logread | grep passwall2-heal`.

### Deploy

```sh
# 1. copy to the router
scp passwall2-heal.sh root@192.168.8.1:/etc/passwall2-heal.sh
ssh root@192.168.8.1 chmod +x /etc/passwall2-heal.sh

# 2. check your SOCKS port (PassWall2 default is 1070 — verify!)
ssh root@192.168.8.1 'curl -x socks5h://127.0.0.1:1070 -m 10 https://api.ipify.org'

# 3. hook into boot: append to /etc/rc.local (before exit 0)
( /etc/passwall2-heal.sh boot ) &

# 4. optional belt-and-suspenders via cron (choose this OR PassWall2's own
#    auto-switch, not both):
*/10 * * * * /etc/passwall2-heal.sh check
```

Also apply the firmware workarounds from §2 (IPv4-only APN, default MTU).
Consider 4G-only mode if you value stability over speed.

## 4. Bonus: two ways your "exit IP" tools lie to you

While chasing this bug we caught two measurement traps that will mislead
anyone debugging proxy routing. Full story in [docs/diagnosis.md](docs/diagnosis.md).

### 4.1 Cloudflare-backed probes go blind exactly when it matters

`api.ipify.org`, `api.trackip.net`, most "what's my IP" endpoints are
Cloudflare-fronted. When PassWall2 routes them through a **dead** tunnel,
they time out instead of answering — so a probe loop shows "100% tunnel IP,
no problem" while the direct egress is actually live with your local carrier
IP. **A truth probe must be reachable both ways** (we used `ipwho.is`).

### 4.2 HTTP/3 (QUIC) bypasses the tunnel and reports the direct IP

PassWall2 (like most OpenWrt proxy setups) routes TCP but **not UDP/443**.
macOS `URLSession` (and Chrome) use HTTP/3 by default to Cloudflare/Google
frontends. Result: an IP-checker app can display your **direct carrier IP**
while the tunnel is perfectly healthy — we caught a menubar app racing
QUIC→GCP (`ifconfig.me`, 0.32 s direct; the GFW blocks TCP to that IP but
passes UDP/443) against TCP→Cloudflare through the tunnel (~0.9 s).
QUIC won every race, and the app "jumped" between the VPN IP and whatever
carrier IP we were roaming on.

If your exit IP "flaps" between your VPN and your travel location's carrier:
**check for QUIC before blaming the proxy.**

## 5. It is not just GL.iNet

The same disease class (cellular session managers tearing down working
data connections) shows up across the travel-router category — e.g. the
Photonicat 2 changelog documents a year of similar fixes ("5G connection
that stops passing traffic", "redial on a timer", "dialer rewritten in C,
watches the data plane"). Roaming makes all of it worse, because home
networks tear down visited PDP sessions more eagerly.

---

## 中文摘要

- **病**: Mudi 7 漫游时 WAN 每 10–30 分钟掉一次(40–60 秒), 每次换新 IP,
  所有会话全死。指纹: `/etc/sys_log` 里 `CallendCode=36`。
- **因**: 固件 bug。4.8.5 有 → 4.10 beta2 修了 → **4.10.0 正式版回退复发**
  (调制解调器控制面脱同步, 把正常工作的链路误拆)。官方 2026-09-11 认账,
  修复版截至 2026-10 未发布。
- **缓解**: APN 的 IP 类型改 **仅 IPv4**; MTU 用默认; 求稳可切 4G-only。
- **自愈**: `passwall2-heal.sh` 零休眠暴力重启 PassWall2, 但探测显式走
  `socks5h://`(不裸奔), WAN 死掉时只等不重启。
- **排障教训**: ① CF 系"查 IP"接口在代理挂掉时只会超时, 会让你误判
  "出口一直是代理 IP"; ② **QUIC(HTTP/3)走 UDP/443, 不过隧道**,
  IP 检测软件可能显示直连 IP 而隧道其实活着 —— 看到出口横跳先查 QUIC。

## License

MIT
