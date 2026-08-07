#!/usr/bin/env bash
#
# Back this agent's persistent state up to a private git repository.
#
#   scripts/backup.sh <repo-url> [--no-wallet]
#
# The token comes from BACKUP_GITHUB_TOKEN or GITHUB_TOKEN in the environment;
# it is never written to disk or printed.
#
# WHY THIS IS A SCRIPT AND NOT A LIST OF STEPS
# Every part of this has a way to fail silently:
#   - `cp` on a live SQLite file can capture a torn write, producing a file that
#     restores cleanly and then fails at open time.
#   - Git normalises "text" files by default; a .db caught by `* text=auto` is
#     corrupted in transit.
#   - Half of ${HERMES_HOME} is symlinks onto the ephemeral disk. Copying those
#     in bloats the backup with content that is rebuilt on every boot anyway.
#   - .env holds every API key, bot token and password in plaintext, and is
#     regenerated from platform env vars on each boot — backing it up is pure
#     downside.
# Encoding the answers once is more reliable than re-deriving them each time.

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
REPO_URL="${1:-${BACKUP_REPO:-}}"
INCLUDE_WALLET=1

for arg in "$@"; do
  [[ "$arg" == "--no-wallet" ]] && INCLUDE_WALLET=0
done

if [[ -z "$REPO_URL" ]]; then
  echo "usage: $0 <repo-url> [--no-wallet]" >&2
  echo "  e.g. $0 https://github.com/you/hermes-backup.git" >&2
  exit 2
fi

TOKEN="${BACKUP_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "[backup] ERROR: set BACKUP_GITHUB_TOKEN or GITHUB_TOKEN first." >&2
  exit 1
fi

# DENY-list, not an allow-list. Back up everything under ${HERMES_HOME} except
# the few things that are provably regenerable or actively harmful to store.
#
# An allow-list looked tidier and was wrong: a real backup repo turned out to
# hold memories/, profiles/ and SOUL.md, none of which a hand-written list had
# thought of. Hermes adds state directories over time, and an allow-list drops
# each new one silently — you only find out when a restore comes back missing
# something. Enumerate what must NOT be kept; let everything else through.
EXCLUDE_NAMES=(
  .env                 # regenerated from platform env vars each boot; all secrets in plaintext
  logs                 # disposable, unbounded
  well-known-skills    # derived from skills/ on every boot

  # Caches. Regenerated on demand, and the media ones get large fast — they are
  # the difference between a backup that pushes and one that does not.
  cache
  audio_cache
  image_cache
  sandboxes            # scratch space for the terminal backend

  # Runtime scratch, meaningless once the process is gone.
  gateway.pid
  gateway-starts.log
)
[[ "$INCLUDE_WALLET" == "1" ]] || EXCLUDE_NAMES+=(.radius-cli)

# Provider/model catalogues re-fetched on demand.
EXCLUDE_GLOBS=('*_cache.json' '*.pid' '*.sock')

# Skipped inside external-skills/: the vendored clone is re-cloned every boot.
EXCLUDE_NESTED=(external-skills/radius-skills)

is_excluded() {
  local name="$1" e g
  for e in "${EXCLUDE_NAMES[@]}"; do
    [[ "$name" == "$e" ]] && return 0
  done
  for g in "${EXCLUDE_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ "$name" == $g ]] && return 0
  done
  return 1
}

STAGING="$(mktemp -d)"
CLONE="$(mktemp -d)"
cleanup() { rm -rf "$STAGING" "$CLONE"; }
trap cleanup EXIT

echo "[backup] Staging state from ${HERMES_HOME}"

# --- databases: snapshot through sqlite3, never a raw copy -------------------
# VACUUM INTO is preferred over .backup: both give a consistent snapshot, but
# VACUUM also rebuilds the file without free pages. A long-running agent's
# state.db carries a lot of those — and shrinking it here is what keeps the
# backup under GitHub's limits and off the volume's ceiling on restore.
shopt -s nullglob
for db in "${HERMES_HOME}"/*.db; do
  name="$(basename "$db")"
  before="$(stat -c%s "$db" 2>/dev/null || echo 0)"

  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 "$db" "VACUUM INTO '${STAGING}/${name}'" 2>/dev/null; then
      after="$(stat -c%s "${STAGING}/${name}" 2>/dev/null || echo 0)"
      echo "[backup]   ${name} (vacuumed snapshot: $((before/1024/1024))MB -> $((after/1024/1024))MB)"
      continue
    fi
    if sqlite3 "$db" ".backup '${STAGING}/${name}'" 2>/dev/null; then
      echo "[backup]   ${name} (sqlite3 snapshot, $((before/1024/1024))MB)"
      continue
    fi
    echo "[backup]   WARNING: sqlite3 snapshot failed for ${name}; falling back to copy." >&2
  fi
  cp -a "$db" "${STAGING}/${name}"
  echo "[backup]   ${name} (raw copy — may be inconsistent if written during copy)"
done
shopt -u nullglob

# --- everything else ---------------------------------------------------------
shopt -s dotglob nullglob
for src in "${HERMES_HOME}"/*; do
  item="$(basename "$src")"

  # Databases were already snapshotted through sqlite3 above.
  [[ "$item" == *.db ]] && continue
  # Their sidecars are meaningless without the live database.
  [[ "$item" == *.db-wal || "$item" == *.db-shm || "$item" == *.lock ]] && continue

  if is_excluded "$item"; then
    echo "[backup]   skipping ${item} (regenerated on boot / must not be stored)"
    continue
  fi

  # A symlink here points at the ephemeral disk: its content is rebuilt on boot,
  # so following it would copy throwaway data into the backup.
  if [[ -L "$src" ]]; then
    echo "[backup]   skipping ${item} (symlink to ephemeral storage)"
    continue
  fi

  if [[ -d "$src" ]]; then
    mkdir -p "${STAGING}/${item}"
    cp -a "${src}/." "${STAGING}/${item}/"
    # Drop nested paths that are regenerable even though their parent is kept.
    for nested in "${EXCLUDE_NESTED[@]}"; do
      [[ "$nested" == "${item}/"* ]] && rm -rf "${STAGING:?}/${nested:?}"
    done
  else
    cp -a "$src" "${STAGING}/${item}"
  fi
  echo "[backup]   ${item}"
done
shopt -u dotglob nullglob

# Also drop any symlinks that came along inside copied directories — they would
# restore as dangling links on a fresh container.
find "$STAGING" -type l -delete 2>/dev/null || true

# --- push --------------------------------------------------------------------
# The token goes into the remote URL for this one clone in a temp dir that is
# deleted on exit, so it is never persisted in a .git/config that outlives the
# run. Output is filtered so the URL cannot reach the log.
AUTH_URL="$(printf '%s' "$REPO_URL" | sed -E "s#^https://#https://x-access-token:${TOKEN}@#")"

echo "[backup] Cloning backup repository"
if ! git clone --quiet --depth 1 "$AUTH_URL" "$CLONE" 2>/dev/null; then
  echo "[backup] Repository is empty or unreachable — initialising a new one."
  git init --quiet "$CLONE"
  git -C "$CLONE" remote add origin "$AUTH_URL"
  git -C "$CLONE" checkout --quiet -b main
fi

git -C "$CLONE" config user.email "hermes@localhost"
git -C "$CLONE" config user.name "Hermes Agent"

# Databases go through Git LFS, not plain git objects.
#
# GitHub hard-rejects any single file over 100MB pushed as a normal blob, and a
# long-running agent's state.db passes that easily — 148MB in the case that
# prompted this. The push fails outright; there is no partial success to notice
# later. LFS also keeps the repository from carrying a full copy of a large
# binary in history on every backup.
#
# The filter attributes double as the EOL protection these files need: without
# `-text`, a repo carrying `* text=auto` corrupts a database in transit.
if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
  git -C "$CLONE" lfs install --local >/dev/null 2>&1 || true
  cat > "${CLONE}/.gitattributes" <<'ATTR'
*.db filter=lfs diff=lfs merge=lfs -text
*.sqlite filter=lfs diff=lfs merge=lfs -text
*.sqlite3 filter=lfs diff=lfs merge=lfs -text
ATTR
  echo "[backup] Databases will be stored via Git LFS."
else
  cat > "${CLONE}/.gitattributes" <<'ATTR'
*.db binary
*.sqlite binary
*.sqlite3 binary
ATTR
  echo "[backup] WARNING: git-lfs is not installed. Files over 100MB will be rejected by GitHub." >&2
fi

# Replace the tracked payload wholesale so deletions propagate.
find "$CLONE" -mindepth 1 -maxdepth 1 ! -name '.git' ! -name '.gitattributes' -exec rm -rf {} +
cp -a "${STAGING}/." "${CLONE}/"

cat > "${CLONE}/BACKUP_INFO.txt" <<INFO
Hermes state backup
created:  $(date -u +%Y-%m-%dT%H:%M:%SZ)
host:     $(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)
wallet:   $([[ "$INCLUDE_WALLET" == "1" ]] && echo "included (.radius-cli holds a PRIVATE KEY)" || echo "excluded")

Restore with:  scripts/restore.sh <this-repo-url>
Excluded by design: .env (regenerated on boot, holds all secrets),
logs/, well-known-skills/, external-skills/radius-skills/ (all rebuilt on boot).
INFO

total_mb="$(du -sm "$STAGING" 2>/dev/null | cut -f1 || echo '?')"
echo "[backup] Payload: ${total_mb}MB"

# Flag anything that will be rejected before spending time on the push.
# Collected into a variable and read via here-string: process substitution needs
# /dev/fd, which is not available in every container runtime.
big_files="$(find "$STAGING" -type f -size +100M 2>/dev/null || true)"
if [[ -n "$big_files" ]]; then
  while IFS= read -r big; do
    [[ -n "$big" ]] || continue
    rel="${big#"$STAGING"/}"
    if ! grep -q "filter=lfs" "${CLONE}/.gitattributes" 2>/dev/null; then
      echo "[backup] WARNING: ${rel} is over 100MB and is not LFS-tracked; GitHub will reject it." >&2
    fi
  done <<< "$big_files"
fi

git -C "$CLONE" add -A
if git -C "$CLONE" diff --cached --quiet; then
  echo "[backup] No changes since the last backup."
  exit 0
fi

git -C "$CLONE" commit --quiet -m "Hermes state backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Capture the real git output. Swallowing it turned a "file too large" rejection
# into a misleading "check your token" message and cost an hour of guessing.
# Scrub the token before anything is printed.
echo "[backup] Pushing (${total_mb}MB — this can take a while)"
push_log="$(git -C "$CLONE" push origin HEAD:main 2>&1)" && push_rc=0 || push_rc=$?
push_log="${push_log//${TOKEN}/<token>}"

if [[ "$push_rc" -eq 0 ]]; then
  echo "[backup] Pushed to main."
else
  echo "[backup] ERROR: push failed. Git said:" >&2
  printf '%s\n' "$push_log" | sed 's/^/[backup]   /' >&2
  case "$push_log" in
    *"exceeds"*|*"too large"*|*"GH001"*)
      echo "[backup] HINT: a file exceeds GitHub's 100MB limit. Ensure git-lfs is installed so databases are LFS-tracked." >&2 ;;
    *403*|*"Permission"*|*"denied"*|*"Authentication"*)
      echo "[backup] HINT: the token cannot write to this repo. It needs 'Contents: read and write' on it." >&2 ;;
    *"quota"*|*"bandwidth"*)
      echo "[backup] HINT: the LFS quota is exhausted (1GB storage/bandwidth on free GitHub accounts)." >&2 ;;
  esac
  exit 1
fi

if [[ "$INCLUDE_WALLET" == "1" ]]; then
  echo "[backup] NOTE: this backup contains the wallet private key (.radius-cli). Keep the repository private."
fi

echo "[backup] Done."
