#!/bin/ash
# /etc/passwall2-heal.sh — passwall2 自愈 v2
# 用法: boot=开机段(等网→校时→受控启动→验证)  check=周期段(连续3败才重启1次)
# 日志: logread | grep passwall2-heal

SOCKS_PORT=1070          # 改成你的节点本地SOCKS端口; 验证: curl -x socks5h://127.0.0.1:端口 https://api.ipify.org
PROBE_URL="http://www.google.com/generate_204"
WAN_PING="223.5.5.5"
LOCK=/tmp/.passwall2-heal.lock
TAG=passwall2-heal

log()  { logger -t "$TAG" -- "$*"; }
lock() { mkdir "$LOCK" 2>/dev/null || { log "already running, exit"; exit 1; }
         trap "rm -rf $LOCK" EXIT; }
wan_up() { ping -c1 -W3 "$WAN_PING" >/dev/null 2>&1; }
core_ready() {
  netstat -ltn 2>/dev/null | awk -v p=":${SOCKS_PORT}\$" '$6=="LISTEN" && $4 ~ p' | grep -q .
}
probe() {  # 显式走代理: 204=通; 其余=不通, 绝不直连
  [ "$(curl -s -o /dev/null -m 8 -w '%{http_code}' \
      -x "socks5h://127.0.0.1:${SOCKS_PORT}" "$PROBE_URL" 2>/dev/null)" = "204" ]
}
wait_wan() {  # $1=最多轮数, 每轮5s
  i=1
  while [ "$i" -le "${1:-60}" ]; do
    wan_up && { log "wan ready (try $i)"; return 0; }
    sleep 5; i=$((i+1))
  done
  log "wan NOT ready after ${1:-60} tries, continue anyway"
  return 1
}
wait_core() { # 轮询就绪(最多60s)
  i=0
  while [ "$i" -lt 20 ]; do
    core_ready && return 0
    sleep 3; i=$((i+1))
  done
  log "core listen port ${SOCKS_PORT} not ready in 60s"
  return 1
}
sync_time() {
  command -v chronyd >/dev/null 2>&1 || { log "no chronyd, skip time sync"; return 0; }
  log "clock before sync: $(date '+%F %T')"
  /etc/init.d/chronyd restart
  sleep 10
  i=1
  while [ "$i" -le 30 ]; do
    chronyc -a makestep >/dev/null 2>&1
    if chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
      log "time synced (try $i): $(date '+%F %T')"
      hwclock -w 2>/dev/null
      return 0
    fi
    sleep 5; i=$((i+1))
  done
  log "time sync FAILED after 30 tries"
  return 1
}
start_pw2() { # WAN死了不重启只等; 每cycle最多3轮+退避; 3轮失败休10分钟再开新cycle, 永不放弃但限速
  cycle=1
  while :; do
  round=1
  while [ "$round" -le 3 ]; do
    if ! wan_up; then
      log "cycle $cycle round $round: WAN down(注册失败?), 重启无意义, 等WAN回来"
      wait_wan 180
      continue
    fi
    [ "$cycle" -eq 1 ] && [ "$round" -eq 1 ] && ACT=start || ACT=restart
    log "cycle $cycle round $round: passwall2 $ACT"
    /etc/init.d/passwall2 "$ACT"
    if wait_core; then
      sleep 5
      if probe; then
        IP=$(curl -s -m 8 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/dev/null)
        log "round $round: proxy OK, egress=${IP:-unknown}"
        return 0
      fi
    fi
    log "cycle $cycle round $round: probe failed, immediately next round"
    round=$((round+1))
  done
  log "cycle $cycle: 3 rounds failed, no sleep, immediately cycle $((cycle+1)) (aggressive mode)"
  cycle=$((cycle+1))
  done
}

case "${1:-boot}" in
  boot)
    lock
    log "== boot heal start =="
    sleep 15
    wait_wan 180 || { log "WAN 30min not ready(注册失败?), boot段退出; 装了cron check就会继续试"; exit 1; }
    sync_time
    start_pw2
    log "== boot heal end =="
    ;;
  check)
    lock
    ok=0
    for i in 1 2 3; do
      probe && { ok=1; break; }
      sleep 20
    done
    [ "$ok" -eq 1 ] && exit 0
    if ! wan_up; then
      log "check: probes failing but WAN is down — not passwall2's fault, no restart"
      exit 1
    fi
    log "check: 3 consecutive failures, single restart"
    /etc/init.d/passwall2 restart
    if wait_core && sleep 5 && probe; then
      log "check: recovered"
    else
      log "check: STILL failing after single restart, giving up (no loop)"
    fi
    ;;
esac
