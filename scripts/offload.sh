#!/usr/bin/env bash
#
# Move a directory off the volume onto the ephemeral disk, and remember the
# decision so it survives redeploys.
#
#   scripts/offload.sh /data/.hermes/plugins/some-plugin/big-model
#
# Run this only after the operator has confirmed the directory is reproducible.
# See disk-check.sh for why that classification cannot be made automatically.
#
# The remembering matters. A bare `mv` plus symlink works until the next
# redeploy, when the ephemeral disk is wiped and the symlink is left dangling —
# and a dangling symlink is worse than a full disk, because `mkdir -p` fails on
# it and takes the whole boot down with it. The path is recorded in
# ${HERMES_HOME}/.offload-list, which the entrypoint replays on every boot.

set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/data/.hermes}"
EPHEMERAL_ROOT="${EPHEMERAL_ROOT:-/opt/hermes-cache}"
LIST="${HERMES_HOME}/.offload-list"

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "usage: $0 <absolute-path-under-${HERMES_HOME}>" >&2
  exit 2
fi

# Resolve without following the final symlink, so re-running on an already
# offloaded path is a no-op rather than a surprise.
TARGET="${TARGET%/}"

case "$TARGET" in
  "${HERMES_HOME}"/*) ;;
  *) echo "[offload] ERROR: refusing to touch a path outside ${HERMES_HOME}: ${TARGET}" >&2
     exit 1 ;;
esac

REL="${TARGET#"${HERMES_HOME}"/}"

# Refuse the things that are never reproducible, even if asked. A typo in a path
# should not be able to move the session history onto a disk that gets wiped.
case "$REL" in
  sessions|sessions/*|memories|memories/*|profiles|profiles/*|state.db|kanban.db) ;&
  .radius-cli|.radius-cli/*|cron|cron/*|config.yaml|.env)
    echo "[offload] ERROR: ${REL} is persistent state and must stay on the volume." >&2
    exit 1 ;;
esac

if [[ -L "$TARGET" ]]; then
  echo "[offload] ${REL} is already offloaded -> $(readlink -f "$TARGET" 2>/dev/null)"
  grep -qxF "$REL" "$LIST" 2>/dev/null || echo "$REL" >> "$LIST"
  exit 0
fi

if [[ ! -d "$TARGET" ]]; then
  echo "[offload] ERROR: ${TARGET} is not a directory." >&2
  exit 1
fi

DEST="${EPHEMERAL_ROOT}/offload-$(printf '%s' "$REL" | tr '/' '-')"
SIZE="$(du -smx "$TARGET" 2>/dev/null | cut -f1 || echo '?')"

mkdir -p "$DEST"
if [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
  cp -a "${TARGET}/." "${DEST}/" 2>/dev/null || {
    echo "[offload] ERROR: copy failed; nothing was removed." >&2
    exit 1
  }
fi

rm -rf "${TARGET:?}"
ln -sfn "$DEST" "$TARGET"

# Record it so the entrypoint recreates the link after the ephemeral disk is
# wiped. Without this the next redeploy leaves a dangling symlink.
mkdir -p "$(dirname "$LIST")"
grep -qxF "$REL" "$LIST" 2>/dev/null || echo "$REL" >> "$LIST"

echo "[offload] Moved ${REL} (${SIZE}MB) to ${DEST}"
echo "[offload] Recorded in ${LIST} — the link is recreated on every boot."
echo "[offload] Contents are on ephemeral storage: they survive restarts, not redeploys."
