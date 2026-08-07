FROM python:3.11-slim AS builder

ARG HERMES_GIT_REF=main

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --depth 1 --branch "${HERMES_GIT_REF}" --recurse-submodules https://github.com/NousResearch/hermes-agent.git

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

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    tini \
    nodejs \
    npm \
  && npm install -g radius-cli \
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
