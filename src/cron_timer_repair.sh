#!/usr/bin/env bash
set -u

TIMER=""
TIMER_ACTION=""
RESTART_CRON=false
FIX_FILE=""
DRY_RUN=false
ASSUME_YES=false
OUTPUT_DIR=""
FAILURES=0
ACTIONS=0

usage() {
  cat <<'EOF'
Usage: cron_timer_repair.sh [options]

  --timer UNIT --action ACTION  Run start, restart, enable, disable or reset-failed.
  --restart-cron                Restart the installed cron or crond service.
  --fix-file FILE               Correct owner and mode on one system cron file.
  --dry-run                     Show commands without changing schedules.
  --yes                         Skip confirmation prompts.
  --output DIR                  Save logs and before/after evidence in DIR.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --timer) TIMER="${2:-}"; shift 2 ;;
    --action) TIMER_ACTION="${2:-}"; shift 2 ;;
    --restart-cron) RESTART_CRON=true; shift ;;
    --fix-file) FIX_FILE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$TIMER" ] && ! $RESTART_CRON && [ -z "$FIX_FILE" ]; then echo "Choose at least one repair action." >&2; exit 2; fi
if [ -n "$TIMER" ]; then
  case "$TIMER" in *.timer) : ;; *) echo "Timer unit must end in .timer." >&2; exit 2 ;; esac
  case "$TIMER_ACTION" in start|restart|enable|disable|reset-failed) : ;; *) echo "Unsupported timer action." >&2; exit 2 ;; esac
  systemctl cat "$TIMER" >/dev/null 2>&1 || { echo "Timer unit not found: $TIMER" >&2; exit 2; }
fi
if [ -n "$FIX_FILE" ]; then
  [ -f "$FIX_FILE" ] || { echo "Schedule file not found: $FIX_FILE" >&2; exit 2; }
  case "$FIX_FILE" in /etc/crontab|/etc/anacrontab|/etc/cron.d/*|/etc/cron.hourly/*|/etc/cron.daily/*|/etc/cron.weekly/*|/etc/cron.monthly/*) : ;; *) echo "Only standard system cron files are supported." >&2; exit 2 ;; esac
fi

STAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${OUTPUT_DIR:-./cron-timer-repair-$STAMP}"
BACKUP_DIR="$OUTPUT_DIR/backup"
mkdir -p "$OUTPUT_DIR" "$BACKUP_DIR"
LOG="$OUTPUT_DIR/repair.log"
BEFORE="$OUTPUT_DIR/before.txt"
AFTER="$OUTPUT_DIR/after.txt"
: > "$LOG"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
confirm() { $ASSUME_YES && return 0; read -r -p "$1 [y/N]: " answer; case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }
run_action() {
  local description="$1"; shift
  ACTIONS=$((ACTIONS + 1)); log "$description"
  if $DRY_RUN; then
    {
      printf 'DRY-RUN:'
      printf ' %q' "$@"
      printf '\n'
    } >> "$LOG"
    return 0
  fi
  if "$@" >> "$LOG" 2>&1; then log "SUCCESS: $description"; return 0; fi
  FAILURES=$((FAILURES + 1)); log "WARNING: $description failed"; return 1
}
run_root() { local description="$1"; shift; if [ "$(id -u)" -eq 0 ]; then run_action "$description" "$@"; else run_action "$description" sudo "$@"; fi; }
collect_state() {
  local destination="$1"
  {
    echo "Collected: $(date -Is)"
    systemctl list-timers --all --no-pager 2>&1 || true
    echo
    systemctl --failed --no-pager 2>&1 || true
    echo
    systemctl status cron crond --no-pager -l 2>&1 || true
    if [ -n "$TIMER" ]; then echo; systemctl status "$TIMER" --no-pager -l 2>&1 || true; systemctl show "$TIMER" -p ActiveState -p UnitFileState -p NextElapseUSecRealtime 2>&1 || true; fi
    if [ -n "$FIX_FILE" ]; then echo; stat -c '%a %U:%G %n' "$FIX_FILE" 2>&1 || true; fi
  } > "$destination"
}

collect_state "$BEFORE"
confirm "Apply the selected schedule repair actions?" || { log "Repair cancelled."; exit 10; }

if $RESTART_CRON; then
  CRON_UNIT=""
  for unit in cron.service crond.service; do systemctl list-unit-files "$unit" >/dev/null 2>&1 && { CRON_UNIT="$unit"; break; }; done
  if [ -n "$CRON_UNIT" ]; then run_root "Restarting $CRON_UNIT" systemctl restart "$CRON_UNIT" || true; else FAILURES=$((FAILURES + 1)); log "WARNING: cron service was not found."; fi
fi

if [ -n "$TIMER" ]; then
  case "$TIMER_ACTION" in
    start) run_root "Starting $TIMER" systemctl start "$TIMER" || true ;;
    restart) run_root "Restarting $TIMER" systemctl restart "$TIMER" || true ;;
    enable) run_root "Enabling and starting $TIMER" systemctl enable --now "$TIMER" || true ;;
    disable) run_root "Disabling and stopping $TIMER" systemctl disable --now "$TIMER" || true ;;
    reset-failed) run_root "Clearing failed state for $TIMER" systemctl reset-failed "$TIMER" || true ;;
  esac
fi

if [ -n "$FIX_FILE" ]; then
  if ! $DRY_RUN; then cp -a "$FIX_FILE" "$BACKUP_DIR/$(basename "$FIX_FILE")" 2>/dev/null || true; fi
  run_root "Setting root ownership on $FIX_FILE" chown root:root "$FIX_FILE" || true
  case "$FIX_FILE" in
    /etc/crontab|/etc/anacrontab|/etc/cron.d/*) run_root "Setting mode 644 on $FIX_FILE" chmod 644 "$FIX_FILE" || true ;;
    *) run_root "Setting executable mode 755 on $FIX_FILE" chmod 755 "$FIX_FILE" || true ;;
  esac
fi

$DRY_RUN || sleep 2
collect_state "$AFTER"
if [ -n "$TIMER" ] && [ "$TIMER_ACTION" != "disable" ] && [ "$TIMER_ACTION" != "reset-failed" ]; then systemctl is-active --quiet "$TIMER" || { FAILURES=$((FAILURES + 1)); log "WARNING: $TIMER is not active after repair."; }; fi
if [ "$FAILURES" -gt 0 ]; then exit 20; fi
log "Schedule repair completed successfully. Actions performed: $ACTIONS"
exit 0
