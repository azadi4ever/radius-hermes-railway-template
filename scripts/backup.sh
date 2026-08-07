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

# Paths worth keeping. Everything here is either irreplaceable or expensive to
# recreate; nothing here is rebuilt from the image on boot.
#
# skills/ and plugins/ ARE included: the boot loop only overwrites the bundled
# entries by name, so anything the agent authored at runtime lives here and is
# lost with the volume if it is not backed up.
INCLUDE=(
  config.yaml
  vendored-skills.json
  .initialized
  .hermes_api_key
  sessions
  cron
  pairing
  skills
  plugins
  .byterover
  external-skills
)
[[ "$INCLUDE_WALLET" == "1" ]] && INCLUDE+=(.radius-cli)

# Deliberately excluded:
#   .env                          regenerated each boot; all secrets in plaintext
#   logs/                         disposable, unbounded
#   well-known-skills/            derived from skills/ each boot
#   external-skills/radius-skills re-cloned each boot (skipped inside the copy)

STAGING="$(mktemp -d)"
CLONE="$(mktemp -d)"
cleanup() { rm -rf "$STAGING" "$CLONE"; }
trap cleanup EXIT

echo "[backup] Staging state from ${HERMES_HOME}"

# --- databases: snapshot through sqlite3, never a raw copy -------------------
shopt -s nullglob
for db in "${HERMES_HOME}"/*.db; do
  name="$(basename "$db")"
  if command -v sqlite3 >/dev/null 2>&1; then
    if sqlite3 "$db" ".backup '${STAGING}/${name}'" 2>/dev/null; then
      echo "[backup]   ${name} (sqlite3 snapshot)"
      continue
    fi
    echo "[backup]   WARNING: sqlite3 snapshot failed for ${name}; falling back to copy." >&2
  fi
  cp -a "$db" "${STAGING}/${name}"
  echo "[backup]   ${name} (raw copy — may be inconsistent if written during copy)"
done
shopt -u nullglob

# --- everything else ---------------------------------------------------------
for item in "${INCLUDE[@]}"; do
  src="${HERMES_HOME}/${item}"
  [[ -e "$src" ]] || continue
  # A symlink here points at the ephemeral disk: its content is rebuilt on boot,
  # so following it would copy in throwaway data.
  if [[ -L "$src" ]]; then
    echo "[backup]   skipping ${item} (symlink to ephemeral storage)"
    continue
  fi
  if [[ -d "$src" ]]; then
    mkdir -p "${STAGING}/${item}"
    # --exclude keeps the vendored clone out even though its parent is included.
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --exclude 'radius-skills' "${src}/" "${STAGING}/${item}/"
    else
      cp -a "${src}/." "${STAGING}/${item}/"
      rm -rf "${STAGING}/${item}/radius-skills"
    fi
  else
    cp -a "$src" "${STAGING}/${item}"
  fi
  echo "[backup]   ${item}"
done

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

# Binary databases must never go through git's EOL normalisation. Without this,
# a repo carrying `* text=auto` silently corrupts them.
cat > "${CLONE}/.gitattributes" <<'ATTR'
*.db binary
*.db-wal binary
*.db-shm binary
*.sqlite binary
*.sqlite3 binary
ATTR

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

git -C "$CLONE" add -A
if git -C "$CLONE" diff --cached --quiet; then
  echo "[backup] No changes since the last backup."
  exit 0
fi

git -C "$CLONE" commit --quiet -m "Hermes state backup $(date -u +%Y-%m-%dT%H:%M:%SZ)"

if git -C "$CLONE" push --quiet origin HEAD:main 2>/dev/null; then
  echo "[backup] Pushed to main."
else
  echo "[backup] ERROR: push failed. Check that the token has write access to the repo." >&2
  exit 1
fi

if [[ "$INCLUDE_WALLET" == "1" ]]; then
  echo "[backup] NOTE: this backup contains the wallet private key (.radius-cli). Keep the repository private."
fi

echo "[backup] Done."
