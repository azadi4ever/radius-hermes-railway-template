#!/usr/bin/env bash
#
# Report anything about disk usage that needs a human decision — and nothing at
# all when there is nothing to decide.
#
#   scripts/disk-check.sh
#
# Silence is the contract. A scheduled job can run this and only speak when
# there is something worth saying, which is what makes it safe to run daily.
#
# WHY THE DECISION IS NOT AUTOMATIC
# Size cannot tell you whether data is reproducible. profiles/ is 77MB of the
# operator's own work; a model cache is 191MB that redownloads itself. Offloading
# on size alone destroys the first to save the second. Only a human (or the
# operator's answer relayed by the agent) can classify an unrecognised directory,
# so this script proposes and never acts.

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
EPHEMERAL_ROOT="${EPHEMERAL_ROOT:-/opt/hermes-cache}"
WARN_PCT="${DISK_WARN_PCT:-75}"
BIG_MB="${DISK_BIG_MB:-40}"

# Directories that are known state and must never be proposed for offloading.
is_protected() {
  case "$1" in
    profiles|sessions|memories|skills|plugins|state|kanban|cron|pairing|hooks) return 0 ;;
    .radius-cli|.byterover|workspace|.claude|bin|a2a-sessions|platforms) return 0 ;;
    pending_messages|external-skills) return 0 ;;
    *) return 1 ;;
  esac
}

findings=""

# --- volume pressure ----------------------------------------------------------
used_pct="$(df --output=pcent /data 2>/dev/null | tr -dc '0-9' || true)"
used_h="$(df -h /data 2>/dev/null | awk 'NR==2 {print $3" of "$2}' || true)"

if [[ -n "$used_pct" && "$used_pct" -ge "$WARN_PCT" ]]; then
  findings+="⚠️ Volume is ${used_pct}% full (${used_h})."$'\n'
fi

# --- large directories the offload rules did not claim ------------------------
candidates="$(find "${HERMES_HOME}" -maxdepth 3 -type d ! -path "${HERMES_HOME}" 2>/dev/null \
  | while IFS= read -r d; do
      [[ -L "$d" ]] && continue
      is_protected "$(basename "$d")" && continue
      sz="$(du -smx "$d" 2>/dev/null | cut -f1)"
      [[ -n "$sz" && "$sz" -ge "$BIG_MB" ]] && printf '%s\t%s\n' "$sz" "$d"
    done | sort -rn || true)"

if [[ -n "$candidates" ]]; then
  findings+=$'\n'"Large directories on the volume that are NOT recognised caches:"$'\n'
  while IFS=$'\t' read -r sz path; do
    [[ -n "$path" ]] || continue
    findings+="  • ${path#"${HERMES_HOME}"/} — ${sz}MB"$'\n'
    findings+="      move:   /app/scripts/offload.sh ${path}"$'\n'
    findings+="      delete: rm -rf ${path}"$'\n'
  done <<< "$candidates"
fi

# --- state.db -----------------------------------------------------------------
db="${HERMES_HOME}/state.db"
if [[ -f "$db" ]]; then
  db_mb="$(( $(stat -c%s "$db" 2>/dev/null || echo 0) / 1024 / 1024 ))"
  if (( db_mb >= 150 )); then
    findings+=$'\n'"state.db is ${db_mb}MB."$'\n'
    findings+="      shrink: hermes sessions prune --older-than 30d"$'\n'
  fi
fi

# --- output -------------------------------------------------------------------
if [[ -z "$findings" ]]; then
  exit 0        # healthy: say nothing
fi

cat <<REPORT
DISK ATTENTION NEEDED

${findings}
Reply with which action you want and I will run it.
"move" keeps the files but puts them on the ephemeral disk (${EPHEMERAL_ROOT}),
which survives restarts but not redeploys — correct for anything redownloadable.
"delete" is permanent.
If it is data you authored, say "keep" and I will leave it alone.
REPORT
exit 1
