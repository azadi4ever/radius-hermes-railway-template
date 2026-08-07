FROM python:3.11-slim AS builder

# Pin the upstream Hermes version. "main" is NOT a version: two builds of the
# same commit of this repo can install different Hermes code, and because the
# clone below is a cacheable Docker layer you also cannot rely on "main" to
# actually be recent. This deployment saw both failure modes in one day —
# 0957277f on one deploy, f15a38ee on the next, neither one asked for.
#
# To upgrade: bump this to a newer tag from
# https://github.com/NousResearch/hermes-agent/releases and redeploy. If the
# new version misbehaves, put the old tag back — that is the whole point of
# pinning. `hermes update` still works at runtime (see below).
ARG HERMES_GIT_REF=v2026.8.3

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
# Cloning with --branch <tag> narrows the remote's fetch refspec to that one
# tag (+refs/tags/<tag>:refs/tags/<tag>), so `git fetch origin main` finds
# nothing and `hermes update` dead-ends. Restoring the standard refspec keeps
# runtime updates working while the build stays pinned and reproducible.
#
# Note that `hermes update` only rewrites /opt/hermes-agent, which lives in the
# image on the ephemeral disk — the update is real but lasts until the next
# redeploy. Bump HERMES_GIT_REF to make a version change permanent.
RUN git clone --depth 1 --branch "${HERMES_GIT_REF}" --recurse-submodules https://github.com/NousResearch/hermes-agent.git \
  && cd hermes-agent \
  && git remote set-branches origin '*' \
  && (git config --unset-all remote.origin.fetch || true) \
  && git config --add remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' \
  && git rev-parse HEAD > .pinned-commit \
  && printf '%s\n' "${HERMES_GIT_REF}" > .pinned-ref \
  && echo "git" > .install_method

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

RUN pip install --no-cache-dir --upgrade pip setuptools wheel
# `mcp` matters: tools/mcp_tool.py guards its imports with a bare
# `except ImportError` and sets _MCP_AVAILABLE=False, and unlike most optional
# deps it is NOT registered for lazy install on the mcp_servers client path.
# Without it, every mcp_servers entry in config.yaml is silently ignored.
RUN pip install --no-cache-dir -e "/opt/hermes-agent[messaging,cron,cli,pty,mcp]"

# Python dependencies for agent_server and radius scripts
RUN pip install --no-cache-dir \
  "fastapi>=0.104.0" \
  "uvicorn[standard]>=0.24.0" \
  "pyjwt[crypto]>=2.8.0" \
  "cryptography>=41.0.0" \
  "httpx>=0.25.0" \
  "a2a-sdk>=0.3.0" \
  "web3>=6.0.0" \
  "requests>=2.28.0"


FROM python:3.11-slim

# Ephemeral cache root for the large, regenerable paths that entrypoint.sh
# symlinks off the Railway volume (see "hermes-state-persistence" there).
#
# NOTE: do NOT create the /data/.hermes symlink here. Railway mounts the volume
# at /data at RUNTIME, which shadows whatever the image has at that path, so a
# build-time link there is invisible to the running container. All of the
# linking has to happen in the entrypoint.
RUN mkdir -p /opt/hermes-cache /data

# git-lfs matters for backup/restore. Agents back their state up to a git repo,
# and anything large there (state.db, kanban.db) is usually stored via LFS.
# Cloning such a repo WITHOUT git-lfs succeeds silently and writes ~130-byte
# pointer files in place of the real content, so a restore looks like it worked
# and Hermes then fails at runtime with "file is not a database".
# `git lfs install --system` registers the smudge/clean filters in /etc/gitconfig
# — installing the package alone is not enough for clones to fetch LFS content.
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    git-lfs \
    jq \
    tini \
    nodejs \
    npm \
  && npm install -g radius-cli \
  && git lfs install --system \
  && rm -rf /var/lib/apt/lists/*

# Install Foundry to a stable path that remains available after HOME is remapped.
ENV FOUNDRY_DIR=/opt/foundry
RUN curl -fsSL https://foundry.paradigm.xyz | bash \
  && /opt/foundry/bin/foundryup

# Install ByteRover before HOME is remapped to /data so it lands in /root/.local/bin
RUN curl -fsSL https://byterover.dev/install.sh | sh

ENV PATH="/root/.local/bin:/opt/foundry/bin:/opt/venv/bin:${PATH}" \
  PYTHONUNBUFFERED=1 \
  HERMES_HOME=/data/.hermes \
  HOME=/data

COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /opt/hermes-agent /opt/hermes-agent

WORKDIR /app
COPY scripts/entrypoint.sh /app/scripts/entrypoint.sh
RUN sed -i 's/\r$//' /app/scripts/entrypoint.sh && chmod +x /app/scripts/entrypoint.sh

COPY scripts/radius /app/scripts/radius
COPY scripts/godaddy /app/scripts/godaddy

# Install and build linear-claude-skill (still Node.js)
RUN git clone --depth 1 https://github.com/radius-workshop/linear-claude-skill /app/scripts/linear-skill \
  && cd /app/scripts/linear-skill \
  && npm install --no-fund --no-audit \
  && npm run build \
  && npm prune --omit=dev

# Bootstrap snapshot only: entrypoint copies this to RADIUS_SKILLS_DIR on /data
# when persistent external skills storage is empty.
RUN git clone --depth 1 https://github.com/radiustechsystems/skills.git /app/vendor/radius-skills

COPY scripts/agent_server /app/scripts/agent_server
COPY erc8004_registry /app/erc8004_registry

COPY HERMES.md /app/HERMES.md
COPY AGENTS.md /app/AGENTS.md
COPY README.md /app/README.md

COPY skills /app/skills
COPY plugins /app/plugins

ENTRYPOINT ["tini", "--"]
CMD ["/app/scripts/entrypoint.sh"]
