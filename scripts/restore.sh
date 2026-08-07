#!/usr/bin/env bash
#
# Restore this agent's state from a private git backup repository.
#
#   scripts/restore.sh <repo-url> [--force]
#
# The token comes from BACKUP_GITHUB_TOKEN or GITHUB_TOKEN in the environment;
# it is never written to disk or printed.
#
# WHAT THIS PROTECTS AGAINST
#   - Git LFS pointers. If the backup repo stores databases in LFS, a clone
#     without git-lfs succeeds and writes ~130-byte text stubs in their place.
#     Nothing errors; Hermes later fails with a bare "file is not a database".
#   - Writing through symlinks. Several paths under ${HERMES_HOME} are symlinks
#     onto the ephemeral disk. Restoring into them puts recovered data somewhere
#     the next redeploy erases.
#   - Clobbering .env. It is regenerated from platform env vars on every boot;
#     an older copy would overwrite live credentials with stale ones.
# Everything is verified BEFORE anything is written, so a bad backup cannot
# half-apply.

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
REPO_URL="${1:-${BACKUP_REPO:-}}"
FORCE=0

for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=1
done

if [[ -z "$REPO_URL" ]]; then
  echo "usage: $0 <repo-url> [--force]" >&2
  exit 2
fi

TOKEN="${BACKUP_GITHUB_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "$TOKEN" ]]; then
  echo "[restore] ERROR: set BACKUP_GITHUB_TOKEN or GITHUB_TOKEN first." >&2
  exit 1
fi

CLONE="$(mktemp -d)"
cleanup() { rm -rf "$CLONE"; }
trap cleanup EXIT

AUTH_URL="$(printf '%s' "$REPO_URL" | sed -E "s#^https://#https://x-access-token:${TOKEN}@#")"

echo "[restore] Cloning backup repository"
# Ask for main explicitly. backup.sh always pushes there, and a repo whose
# default branch is something else (or whose HEAD is unset) otherwise checks out
# the wrong thing — or nothing at all — and the restore silently applies an
# empty tree.
if ! git clone --quiet --depth 1 --branch main "$AUTH_URL" "$CLONE" 2>/dev/null; then
  rm -rf "$CLONE" && mkdir -p "$CLONE"
  if ! git clone --quiet --depth 1 "$AUTH_URL" "$CLONE" 2>/dev/null; then
    echo "[restore] ERROR: clone failed. Check the URL and that the token can read the repo." >&2
    exit 1
  fi
  echo "[restore] NOTE: no 'main' branch; using the repository default."
fi

if [[ -z "$(ls -A "$CLONE" 2>/dev/null | grep -v '^\.git$')" ]]; then
  echo "[restore] ERROR: the backup repository is empty. Nothing to restore." >&2
  exit 1
fi

# Fetch LFS content if the repo uses it. Without this the databases are pointer
# stubs and the restore silently produces garbage.
if [[ -f "${CLONE}/.gitattributes" ]] && grep -q 'filter=lfs' "${CLONE}/.gitattributes" 2>/dev/null; then
  if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
    echo "[restore] Repository uses Git LFS — fetching content"
    # Register the filters for THIS clone before pulling. Having the binary on
    # PATH is not enough: without the hooks, `lfs pull` declines to run and the
    # pointer stubs stay in place — the same silent failure this whole check
    # exists to catch.
    git -C "$CLONE" lfs install --local >/dev/null 2>&1 || true
    lfs_log="$(git -C "$CLONE" lfs pull 2>&1)" || {
      echo "[restore] ERROR: 'git lfs pull' failed. Aborting rather than restoring pointer stubs." >&2
      printf '%s\n' "${lfs_log//${TOKEN}/<token>}" | sed 's/^/[restore]   /' >&2
      exit 1
    }
  else
    echo "[restore] ERROR: repository uses Git LFS but git-lfs is not installed." >&2
    echo "[restore]        Run: apt-get update && apt-get install -y git-lfs && git lfs install" >&2
    exit 1
  fi
fi

# --- verify the payload BEFORE touching live state ---------------------------
echo "[restore] Verifying backup contents"
problems=0

lfs_hits="$(find "$CLONE" -path "${CLONE}/.git" -prune -o -type f -size -200c -print 2>/dev/null \
            | while IFS= read -r f; do
                head -c 40 "$f" 2>/dev/null | grep -q 'git-lfs' && echo "$f"
              done || true)"
if [[ -n "$lfs_hits" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && { echo "[restore]   BROKEN: ${f#"$CLONE"/} is an LFS pointer, not content." >&2; problems=$((problems+1)); }
  done <<< "$lfs_hits"
fi

shopt -s nullglob
for db in "$CLONE"/*.db; do
  name="$(basename "$db")"
  if [[ "$(head -c 15 "$db" 2>/dev/null)" != "SQLite format 3" ]]; then
    echo "[restore]   BROKEN: ${name} is not a SQLite database ($(stat -c%s "$db") bytes)." >&2
    problems=$((problems+1))
    continue
  fi
  if command -v sqlite3 >/dev/null 2>&1; then
    if ! sqlite3 "$db" "PRAGMA integrity_check;" 2>/dev/null | grep -qx ok; then
      echo "[restore]   BROKEN: ${name} fails PRAGMA integrity_check." >&2
      problems=$((problems+1))
      continue
    fi
  fi
  echo "[restore]   ok: ${name}"
done
shopt -u nullglob

if (( problems > 0 )); then
  echo "[restore] ABORTED: ${problems} file(s) in the backup are damaged. Nothing was changed." >&2
  echo "[restore] Fix the backup (usually: re-run it with git-lfs available) and try again." >&2
  exit 1
fi

# --- apply -------------------------------------------------------------------
if [[ "$FORCE" != "1" ]]; then
  echo "[restore] Backup verified. Applying to ${HERMES_HOME}"
  echo "[restore] Existing files will be overwritten. Restart the service afterwards."
fi

applied=0
skipped=0

for src in "$CLONE"/* "$CLONE"/.[!.]*; do
  [[ -e "$src" ]] || continue
  name="$(basename "$src")"

  case "$name" in
    .git|.gitattributes|BACKUP_INFO.txt)
      continue ;;
    # Never restore these: .env is rebuilt from platform env vars on every boot
    # and an old copy would install stale credentials.
    .env|logs|well-known-skills)
      echo "[restore]   skipping ${name} (regenerated on boot)"
      skipped=$((skipped+1))
      continue ;;
  esac

  dest="${HERMES_HOME}/${name}"

  # Never write through a symlink — that lands the data on the ephemeral disk,
  # where the next redeploy erases it.
  if [[ -L "$dest" ]]; then
    echo "[restore]   skipping ${name} (live symlink to ephemeral storage)"
    skipped=$((skipped+1))
    continue
  fi

  if [[ -d "$src" ]]; then
    mkdir -p "$dest"
    cp -a "${src}/." "${dest}/"
  else
    cp -a "$src" "$dest"
  fi
  echo "[restore]   restored ${name}"
  applied=$((applied+1))
done

# The wallet key and API key must not be world-readable after restore.
chmod 600 "${HERMES_HOME}/.hermes_api_key" 2>/dev/null || true
chmod -R go-rwx "${HERMES_HOME}/.radius-cli" 2>/dev/null || true

echo "[restore] Restored ${applied} item(s), skipped ${skipped}."
echo "[restore] RESTART the service now — Hermes holds the old databases open until it does."
