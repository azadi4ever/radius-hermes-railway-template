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
INCLUDE_WALLET=1

for arg in "$@"; do
  [[ "$arg" == "--no-wallet" ]] && INCLUDE_WALLET=0
done

# from_hermes_env <KEY>
# Read a value out of ${HERMES_HOME}/.env.
#
# The platform's variables are not always visible to whatever process ends up
# invoking this. An agent's terminal tool may run with a scrubbed environment —
# sensible on its part, since it is exactly how a prompt-injected command would
# read a secret — and the script then fails with "token not set" on a deployment
# where the variable is plainly configured.
#
# The entrypoint writes the same values to ${HERMES_HOME}/.env (mode 0600) for
# Hermes itself, so that file is the authoritative fallback.
from_hermes_env() {
  local key="$1" file="${HERMES_HOME}/.env" val
  [[ -r "$file" ]] || return 0
  val="$(sed -n "s/^${key}=//p" "$file" | head -n1)"
  # Tolerate values written with surrounding quotes.
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  printf '%s' "$val"
}

REPO_URL="${1:-${BACKUP_REPO:-}}"
[[ "$REPO_URL" == --* ]] && REPO_URL=""
[[ -z "$REPO_URL" ]] && REPO_URL="$(from_hermes_env BACKUP_REPO)"

if [[ -z "$REPO_URL" ]]; then
  echo "[backup] ERROR: no repository. Pass one, or set BACKUP_REPO." >&2
  echo "  e.g. $0 https://github.com/you/hermes-backup.git" >&2
  exit 2
fi

# How many backup snapshots to keep in the repository's history. Each backup
# commits a full copy of the state, so an unbounded history only grows.
KEEP="${BACKUP_KEEP:-2}"

TOKEN="${BACKUP_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  TOKEN="$(from_hermes_env BACKUP_GITHUB_TOKEN)"
  [[ -z "$TOKEN" ]] && TOKEN="$(from_hermes_env GITHUB_TOKEN)"
  [[ -n "$TOKEN" ]] && echo "[backup] Token read from ${HERMES_HOME}/.env"
fi
if [[ -z "$TOKEN" ]]; then
  echo "[backup] ERROR: no token. Set BACKUP_GITHUB_TOKEN or GITHUB_TOKEN in the" >&2
  echo "  platform's variables, or pass it for this command only." >&2
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

  snapshotted=0
  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 "$db" "VACUUM INTO '${STAGING}/${name}'" 2>/dev/null; then
      snapshotted=1
    elif sqlite3 "$db" ".backup '${STAGING}/${name}'" 2>/dev/null; then
      snapshotted=1
    else
      echo "[backup]   WARNING: sqlite3 snapshot failed for ${name}; falling back to copy." >&2
    fi
  fi
  if [[ "$snapshotted" != "1" ]]; then
    cp -a "$db" "${STAGING}/${name}"
    echo "[backup]   ${name} (raw copy — may be inconsistent if written during copy)"
  fi

  # Compress. A SQLite file is mostly repetitive structure and text, so gzip
  # takes a vacuumed 102MB database to roughly a quarter of that. Crossing back
  # under GitHub's 100MB blob limit is the point: it takes Git LFS out of the
  # picture entirely, and with it the 1GB free-tier storage and bandwidth quota
  # that nightly backups of a 100MB file would exhaust within a week.
  if command -v gzip >/dev/null 2>&1 && [[ -f "${STAGING}/${name}" ]]; then
    gzip -6 -f "${STAGING}/${name}"
    final="$(stat -c%s "${STAGING}/${name}.gz" 2>/dev/null || echo 0)"
    echo "[backup]   ${name}.gz ($((before/1024/1024))MB -> $((final/1024/1024))MB after vacuum+gzip)"
  else
    after="$(stat -c%s "${STAGING}/${name}" 2>/dev/null || echo 0)"
    echo "[backup]   ${name} ($((before/1024/1024))MB -> $((after/1024/1024))MB)"
  fi
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
# Deep enough to see the commits retention needs to inspect, shallow enough not
# to drag down the entire backup history.
if ! git clone --quiet --depth "$((KEEP + 1))" "$AUTH_URL" "$CLONE" 2>/dev/null; then
  echo "[backup] Repository is empty or unreachable — initialising a new one."
  git init --quiet "$CLONE"
  git -C "$CLONE" remote add origin "$AUTH_URL"
  git -C "$CLONE" checkout --quiet -b main
fi

git -C "$CLONE" config user.email "hermes@localhost"
git -C "$CLONE" config user.name "Hermes Agent"

# Plain git objects by default; LFS only for what genuinely needs it.
#
# GitHub hard-rejects any single blob over 100MB, and an un-gzipped state.db
# clears that easily. LFS solves the limit but introduces a worse one: the free
# tier gives 1GB of LFS storage and 1GB of monthly bandwidth, so nightly backups
# of a 100MB object exhaust it inside a week. Compressing the databases (above)
# brings them under the blob limit instead, which sidesteps the quota entirely.
#
# `binary` is not optional even for the .gz: a repo carrying `* text=auto` would
# otherwise apply EOL normalisation and corrupt them.
cat > "${CLONE}/.gitattributes" <<'ATTR'
*.gz binary
*.db binary
*.sqlite binary
*.sqlite3 binary
ATTR

# Anything still over the limit after compression has to go through LFS.
oversized="$(find "$STAGING" -type f -size +95M 2>/dev/null || true)"
if [[ -n "$oversized" ]]; then
  if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
    git -C "$CLONE" lfs install --local >/dev/null 2>&1 || true
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      rel="${f#"$STAGING"/}"
      printf '%s filter=lfs diff=lfs merge=lfs -text\n' "$rel" >> "${CLONE}/.gitattributes"
      echo "[backup] ${rel} is over 95MB — tracking it with Git LFS."
    done <<< "$oversized"
    echo "[backup] NOTE: LFS is in use. The free tier allows 1GB storage and 1GB/month bandwidth." >&2
  else
    echo "[backup] WARNING: a file exceeds 95MB and git-lfs is unavailable; GitHub will reject the push." >&2
  fi
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

# --- retention ----------------------------------------------------------------
# Keep only the most recent BACKUP_KEEP snapshots.
#
# Every backup commits a fresh copy of the whole state, so an unbounded history
# grows by roughly the payload size each time and never shrinks. Left alone this
# walks into GitHub's repository size limits.
#
# The branch is rebuilt from scratch with `git commit-tree`, reusing the trees
# already in the object store — no checkouts, no working-tree churn. Older
# commits become unreachable and GitHub garbage-collects them.
#
# NOTE: unreachable Git LFS objects are NOT collected automatically. A repo that
# ever pushed via LFS keeps consuming quota until it is deleted and recreated.
# Compressed backups avoid LFS entirely, so this only matters for history that
# predates that change.
if [[ "$KEEP" -ge 1 ]] 2>/dev/null; then
  total="$(git -C "$CLONE" rev-list --count HEAD 2>/dev/null || echo 1)"

  if [[ "$total" -gt "$KEEP" ]]; then
    # Oldest-first list of the commits to keep, newest last.
    keep_list="$(git -C "$CLONE" rev-list --max-count="$KEEP" HEAD | tac)"

    parent=""
    while IFS= read -r c; do
      [[ -n "$c" ]] || continue
      tree="$(git -C "$CLONE" rev-parse "${c}^{tree}")"
      msg="$(git -C "$CLONE" log -1 --format=%s "$c")"
      if [[ -z "$parent" ]]; then
        parent="$(git -C "$CLONE" commit-tree "$tree" -m "$msg")"
      else
        parent="$(git -C "$CLONE" commit-tree "$tree" -p "$parent" -m "$msg")"
      fi
    done <<< "$keep_list"

    git -C "$CLONE" update-ref HEAD "$parent"
    echo "[backup] History truncated to the last ${KEEP} backup(s) (was ${total})."
    FORCE_PUSH=1
  fi
fi

# Capture the real git output. Swallowing it turned a "file too large" rejection
# into a misleading "check your token" message and cost an hour of guessing.
# Scrub the token before anything is printed.
echo "[backup] Pushing (${total_mb}MB — this can take a while)"
# Rewriting history for retention means the push is no longer a fast-forward.
push_args=(push origin HEAD:main)
[[ "${FORCE_PUSH:-0}" == "1" ]] && push_args=(push --force origin HEAD:main)
push_log="$(git -C "$CLONE" "${push_args[@]}" 2>&1)" && push_rc=0 || push_rc=$?
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
