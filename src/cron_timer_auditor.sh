#!/usr/bin/env bash
set -u

HOURS=24
OUTPUT_DIR=""

usage() {
  echo "Usage: cron_timer_auditor.sh [--hours N] [--output DIR]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) HOURS="${2:-24}"; shift 2 ;;
    --output) OUTPUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ "$HOURS" =~ ^[0-9]+$ ]] || { echo "--hours must be numeric" >&2; exit 2; }

STAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_DIR:-./schedule-audit-$STAMP}"
mkdir -p "$OUTPUT_DIR"
REPORT="$OUTPUT_DIR/schedule-audit.txt"
CSV="$OUTPUT_DIR/schedules.csv"
JSON="$OUTPUT_DIR/summary.json"
ERRORS="$OUTPUT_DIR/command-errors.log"
: > "$REPORT"
: > "$ERRORS"
echo 'source,owner,schedule,command,status' > "$CSV"

section() {
  local title="$1"
  shift
  {
    printf '\n===== %s =====\n' "$title"
    "$@"
  } >> "$REPORT" 2>> "$ERRORS" || true
}

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "$value"
}

record_schedule() {
  local source="$1" owner="$2" schedule="$3" command="$4" status="$5"
  printf '%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$source")" \
    "$(csv_escape "$owner")" \
    "$(csv_escape "$schedule")" \
    "$(csv_escape "$command")" \
    "$(csv_escape "$status")" >> "$CSV"
}

have() { command -v "$1" >/dev/null 2>&1; }

section "Collection metadata" bash -c 'date -Is; hostname -f 2>/dev/null || hostname; cat /etc/os-release 2>/dev/null || true; id'
section "System cron configuration" bash -c 'for f in /etc/crontab /etc/anacrontab; do [[ -r "$f" ]] && { echo "--- $f"; sed -n "1,240p" "$f"; }; done'
section "Cron directories" bash -c 'find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly -maxdepth 2 -type f -printf "%M %u:%g %TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | sort || true'
section "Cron spool inventory" bash -c 'find /var/spool/cron /var/spool/cron/crontabs -maxdepth 2 -type f -printf "%M %u:%g %TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | sort || true'
section "Pending at jobs" bash -c 'atq 2>/dev/null || true'

if have systemctl; then
  section "All systemd timers" systemctl list-timers --all --no-pager
  section "Failed timer units" systemctl --failed --type=timer --no-pager
fi

if have journalctl; then
  section "Recent cron events" bash -c "journalctl --since '$HOURS hours ago' --no-pager 2>/dev/null | grep -Ei 'CRON|crond|anacron|systemd.*timer|Started .*timer|Failed .*timer' | tail -n 1000 || true"
fi

TOTAL_CRON=0
TOTAL_TIMERS=0
FAILED_TIMERS=0
UNSAFE_FILES=0
DUPLICATES=0

parse_cron_file() {
  local file="$1" owner="$2" system_format="$3"
  [[ -r "$file" ]] || return 0

  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue

    TOTAL_CRON=$((TOTAL_CRON + 1))
    local schedule command job_owner
    if [[ "$line" =~ ^@ ]]; then
      schedule="$(awk '{print $1}' <<< "$line")"
      if [[ "$system_format" == "true" ]]; then
        job_owner="$(awk '{print $2}' <<< "$line")"
        command="$(cut -d' ' -f3- <<< "$line")"
      else
        job_owner="$owner"
        command="$(cut -d' ' -f2- <<< "$line")"
      fi
    else
      schedule="$(awk '{print $1,$2,$3,$4,$5}' <<< "$line")"
      if [[ "$system_format" == "true" ]]; then
        job_owner="$(awk '{print $6}' <<< "$line")"
        command="$(cut -d' ' -f7- <<< "$line")"
      else
        job_owner="$owner"
        command="$(cut -d' ' -f6- <<< "$line")"
      fi
    fi
    record_schedule "$file" "$job_owner" "$schedule" "$command" "Configured"
  done < "$file"
}

parse_cron_file /etc/crontab root true
for file in /etc/cron.d/*; do
  [[ -f "$file" ]] && parse_cron_file "$file" root true
done

for spool in /var/spool/cron/* /var/spool/cron/crontabs/*; do
  [[ -f "$spool" ]] || continue
  parse_cron_file "$spool" "$(basename "$spool")" false
done

if have systemctl; then
  while IFS='|' read -r unit next left last passed activates; do
    [[ -z "$unit" ]] && continue
    TOTAL_TIMERS=$((TOTAL_TIMERS + 1))
    active_state="$(systemctl show "$unit" -p ActiveState --value 2>>"$ERRORS")"
    unit_state="$(systemctl is-enabled "$unit" 2>>"$ERRORS" || true)"
    persistent="$(systemctl show "$unit" -p Persistent --value 2>>"$ERRORS")"
    status="$active_state/$unit_state"
    [[ "$active_state" == "failed" ]] && FAILED_TIMERS=$((FAILED_TIMERS + 1))
    record_schedule "$unit" root "next=$next; last=$last; persistent=${persistent:-unknown}" "$activates" "$status"
  done < <(systemctl list-timers --all --no-legend --no-pager 2>>"$ERRORS" | awk '{unit=$(NF-1); activates=$NF; $NF=""; $(NF-1)=""; print unit"|"$1" "$2" "$3" "$4"|"$5"|"$6" "$7" "$8" "$9"|"$10"|"activates}')
fi

while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  mode="$(stat -c '%a' "$file" 2>/dev/null || echo unknown)"
  owner="$(stat -c '%U' "$file" 2>/dev/null || echo unknown)"
  if [[ -w "$file" && "$owner" != "root" ]]; then
    UNSAFE_FILES=$((UNSAFE_FILES + 1))
    printf 'Unsafe ownership/write access: %s owner=%s mode=%s\n' "$file" "$owner" "$mode" >> "$REPORT"
  fi
done < <(find /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly /var/spool/cron /var/spool/cron/crontabs -type f 2>/dev/null)

DUPLICATES="$(awk -F, 'NR>1 {key=$3"|"$4; count[key]++} END {for (k in count) if (count[k]>1) d++; print d+0}' "$CSV")"

OVERALL="Healthy"
if [[ "$FAILED_TIMERS" -gt 0 || "$UNSAFE_FILES" -gt 0 || "$DUPLICATES" -gt 0 ]]; then
  OVERALL="Attention required"
fi

cat > "$JSON" <<EOF
{
  "collected_at": "$(date -Is)",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "cron_entries_detected": $TOTAL_CRON,
  "systemd_timers_detected": $TOTAL_TIMERS,
  "failed_timers": $FAILED_TIMERS,
  "unsafe_schedule_files": $UNSAFE_FILES,
  "duplicate_schedule_patterns": $DUPLICATES,
  "overall_status": "$OVERALL"
}
EOF

printf '\nSchedule audit completed: %s\n' "$OUTPUT_DIR" | tee -a "$REPORT"
