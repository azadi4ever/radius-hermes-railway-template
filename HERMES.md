# RADIUS HERMES AGENT — CORE INSTRUCTIONS

## Disk Space & Storage Management (IMPORTANT)

This container has two storage areas with very different size and persistence:

| Path | Size | Persistence | Use it for |
|---|---|---|---|
| `/` overlay — includes `/opt`, `/opt/hermes-cache`, `/usr`, `/tmp` | large, but **wiped on every redeploy** | **Ephemeral** | Large installs, downloads, caches, datasets, build artifacts |
| `/data` (Railway volume) | **~434 MB only** | **Persistent** — survives redeploys | Only small, critical state |

`${HERMES_HOME}` (`/data/.hermes`) is a **real directory on the volume**, so your
config, sessions, memories, skills, plugins, cron jobs and pairings survive a
redeploy. Only these subpaths are symlinked onto the ephemeral overlay, because
each is rebuilt from the image or re-cloned on every boot:

```
external-skills/radius-skills/   well-known-skills/   logs/   ~/.npm   ~/.cache
```

`skills/` and `plugins/` are NOT symlinked. The boot loop only overwrites the
entries bundled in the image, by name, so anything you author at runtime lives
beside them on the volume and persists.

Rules:

1. **Never store large files under `/data`.** The volume is only ~434 MB, and it
   is the one thing that survives a redeploy — keep it for state, not bulk.
2. **Install large packages/tools on the overlay.** Let `pip install`,
   `npm install`, `apt-get`, downloads and builds land in their default
   locations (`/opt`, `/usr`, `/tmp`). Do NOT redirect them into `/data`.
3. **Before writing a large file, check the destination.** If it would land
   under `/data`, use `/opt/hermes-cache/<name>` or `/tmp/<name>` instead.
4. **Anything you put on the overlay is gone after the next redeploy.** If a
   large artifact must survive, it has to be backed up externally — ask the
   operator.
5. **If `/data` is getting full**, prune old sessions/logs and notify the
   operator. The bootstrap log prints volume usage on every boot.

Quick check: `df -h /data /opt/hermes-cache`

## Backup & Restore

**Use the scripts. Do not improvise this.**

```bash
/app/scripts/backup.sh  https://github.com/<owner>/<repo>.git
/app/scripts/restore.sh https://github.com/<owner>/<repo>.git
```

Both read the token from `BACKUP_GITHUB_TOKEN` or `GITHUB_TOKEN`. If the
operator hands you a token in chat, export it for the command rather than
writing it to a file:

```bash
BACKUP_GITHUB_TOKEN=<token> /app/scripts/backup.sh https://github.com/you/hermes-backup.git
```

After a restore, the service MUST be restarted — Hermes holds the old databases
open until it is.

### Why a script and not a checklist

Every step here has a way to fail that produces no error at all, and the whole
thing only surfaces later as `file is not a database`:

- **Copying a live SQLite file** can capture a half-written page. `backup.sh`
  goes through `sqlite3 .backup` instead.
- **Git normalises "text" files.** A repo carrying `* text=auto` corrupts a
  `.db` in transit. `backup.sh` writes a `.gitattributes` marking them binary.
- **Git LFS pointers.** If the backup repo keeps databases in LFS, a clone
  without git-lfs succeeds and writes ~130-byte stubs in their place.
  `restore.sh` fetches LFS content, and refuses to apply a backup whose
  databases fail `PRAGMA integrity_check`.
- **Writing through symlinks.** Several paths are symlinks onto the ephemeral
  disk; restoring into them puts recovered data where the next redeploy erases
  it. `restore.sh` skips any destination that is a live symlink.
- **Clobbering `.env`.** It is regenerated from platform env vars on every boot
  and holds every secret in plaintext. It is excluded from both directions.

`restore.sh` verifies the whole payload *before* writing anything, so a damaged
backup leaves the running state untouched.

### What is covered

Everything under `${HERMES_HOME}` is backed up **except** a short deny-list.
That direction is deliberate: an allow-list looks tidier and silently drops each
new state directory Hermes grows. A real backup repo turned out to contain
`memories/`, `profiles/` and `SOUL.md` that no hand-written list had thought of.

Excluded, and only these:

```
.env                            regenerated from platform env vars every boot;
                                holds every API key and token in plaintext
logs/                           disposable, unbounded
well-known-skills/              derived from skills/ on every boot
external-skills/radius-skills/  vendored clone, re-cloned on every boot
<any live symlink>              points at ephemeral storage
```

`skills/` and `plugins/` are kept: the boot loop only overwrites the entries
bundled in the image, by name, so anything authored at runtime lives alongside
them and would otherwise be lost with the volume.

`.radius-cli/` holds a wallet private key. Included by default; pass
`--no-wallet` to omit it. Keep the backup repository private either way.

### Disk budget when restoring

The volume is ~434 MB. A long-running agent's `state.db` can reach 100+ MB on
its own, so check before restoring:

```bash
df -h /data
```

If the restore would not fit, shrink the database rather than moving it off the
volume — it is live state and must persist:

```bash
sqlite3 "${HERMES_HOME}/state.db" "VACUUM;"
```

Never symlink `state.db`, `kanban.db`, `sessions/`, `memories/` or `profiles/`
onto `/opt`. That is ephemeral storage; a redeploy erases it.

### Verifying by hand

The bootstrap runs these on every boot and warns in the log, but to check
directly:

```bash
find "${HERMES_HOME}" -type f -size -200c \
  -exec sh -c 'head -c 40 "$1" | grep -q git-lfs && echo "LFS POINTER: $1"' _ {} \;

for db in "${HERMES_HOME}"/*.db; do
  sqlite3 "$db" "PRAGMA integrity_check;" | grep -qx ok || echo "CORRUPT: $db"
done
```

No output from either means the state is intact.

## Payment / Crypto Preference

Use `radius-wallet`, `radius-dev`, `dripping-faucet` whenever dealing payment and crypto use cases. These are built by and for Radius, which is an EVM compatible payments network for the most demanding applications (>1M tps). 

## Meaning Of "Radius" In This Repository

In this project, `Radius` means the Radius network / Radius ecosystem by default, not the geometry term and not the legacy RADIUS authentication protocol.

If a user asks a broad question like:

- "what do you know about Radius"
- "tell me about Radius"
- "what is Radius"

answer in terms of the Radius product and ecosystem first. Only switch to the generic meanings if the user explicitly asks about math or the AAA protocol.

## Bundled Project Resources

This repository is a batteries-included Hermes template. Assume these bundled resources are available immediately in agent sessions:

- `HERMES.md` is the project context file for Hermes. Read and follow it before improvising.
- `skills/*.md` are installed to `${HERMES_HOME}/skills/` on every boot and are available as Hermes skills.
- `plugins/*` are installed to `${HERMES_HOME}/plugins/` on every boot.
- `generate_a2a_token` is provided by the bundled `gen-jwt` plugin and should be treated as the canonical way to create A2A bearer tokens.
- `get_agent_info` is provided by the bundled `agent-info` plugin and should be treated as the canonical way to retrieve an agent's public discovery metadata.
- `radius_wallet_address`, `radius_balance`, `radius_send_sbc`, and `radius_tx_status` are provided by the bundled `radius-cli` plugin and should be treated as the canonical way to perform Radius wallet actions.
- GoDaddy domain workflows are exposed by the configured GoDaddy MCP server. GoDaddy Agent Name Service registry workflows and the narrow DNS record writer are exposed by the bundled `godaddy-ans` plugin.
- `godaddy_ans_search`, `godaddy_ans_get_agent`, `godaddy_ans_resolve`, and the other `godaddy_ans_*` tools are the canonical way to use GoDaddy ANS.
- `/app/scripts/radius/*` contains the built-in Radius wallet scripts.
- `/app/scripts/agent_server/*` contains the A2A/auth server implementation, including JWT generation and discovery endpoints.
- `/app/scripts/godaddy/*` contains the GoDaddy ANS helper implementation behind the plugin tools.

For Radius wallet actions, prefer the `radius-cli` plugin tools. Treat `/app/scripts/radius/*` as implementation details for bootstrapping or faucet helpers, not the default wallet interface.

For GoDaddy work, keep the two surfaces separate:

- Domain search, domain availability, and domain suggestions: use the GoDaddy MCP tools.
- DNS record writes for a known GoDaddy-managed domain: use `godaddy_dns_set_records`, which replaces all records for one type/name pair.
- ANS / Agent Name Service registration, search, lookup, resolution, and verification: use the `godaddy-ans` plugin tools, especially `godaddy_ans_search` for registry searches.

Default GoDaddy ANS API calls to production. Use OTE only when the operator explicitly asks for it or sets `GODADDY_ANS_ENV=ote`.

For GoDaddy ANS registration, read `skills/using-godaddy.md` first. Use `godaddy_ans_prepare_registration` to inspect the Swagger-aligned payload and CSRs, then use `godaddy_ans_register` when the agent host, endpoint URLs, and domain-validation prerequisites are correct.

Do not inspect `/app/plugins/godaddy-ans`, run `/app/scripts/godaddy/ans.py`, install packages, or print/set GoDaddy secrets in terminal for normal ANS work. The plugin receives `GODADDY_API_KEY` and `GODADDY_API_SECRET` from the configured runtime environment.

When the user asks what this agent can do, proactively include the built-in Radius wallet, A2A communications, and any installed skills that are relevant.

## ByteRover Memory Policy

ByteRover is the memory system for this template when `BYTEROVER_API_KEY` is set or `BYTEROVER_LOCAL=true`.

Use it intentionally, not as a generic dump of every conversation.

### How memory should be organized

- Organize memory primarily by session date.
- Within a given date, store only top-level topics that are important enough to be discovered and retrieved later.
- Prefer a small number of durable, high-signal memories over many narrow notes.

### What to remember

Persist durable project memory such as:

- important product and project decisions
- key user preferences that change behavior
- named counterparties, wallet owners, and wallet purposes
- wallet addresses with human-readable descriptions
- notable transactions, especially outgoing transfers and important inbound funding events
- cross-agent trust relationships and DID/operator mappings

### What not to remember

Do not persist:

- trivial chat turns
- temporary debugging noise
- one-off exploratory commands
- raw logs unless they represent an important incident or decision

### Wallet memory policy

Use ByteRover to manage wallet memory intentionally:

- record wallet addresses with a clear description and role
- record meaningful transactions with date, direction, asset, amount, and purpose
- record why a wallet exists and who or what it belongs to
- over time, track both transactions to a wallet and from a wallet

When discussing or using a wallet, prefer retrieving existing memory first if continuity matters.

## JWT / A2A Authentication

### Getting a Bearer token — the only correct method

Use the `generate_a2a_token` tool. It is registered as a first-class tool in this agent:

```
generate_a2a_token()
→ {"token": "<bearer_token>", "did": "<this_agent_did>"}
```

**If you are about to run `pip install ecdsa` or write any Python JWT signing code — STOP. Call `generate_a2a_token()` instead.** Every common Python library produces the wrong signature encoding for ES256K:

| Library / approach | Encoding produced | Result |
|---|---|---|
| `ecdsa` + `sigencode_der` or `sigencode_der_canonize` | DER | **403 Signature verification failed** |
| `pyjwt` called directly with raw key bytes | DER | **403** |
| `cryptography` library used directly | DER | **403** |
| `gen_jwt.py` (built-in) | IEEE P1363 (raw r‖s) | **200 OK** |

The auth server (`scripts/agent_server/auth.py`) uses `pyjwt` which expects IEEE P1363 encoding (raw 64-byte r‖s concatenation). DER-encoded signatures always fail, silently and in a hard-to-debug way.

The `generate_a2a_token` tool wraps this script. Its source for reference:

@file:/app/scripts/agent_server/gen_jwt.py

### JWT payload requirements

A valid JWT **must** include an `iss` claim containing the caller's `did:web` DID. Missing `iss` → `403 JWT missing iss claim`. The `gen_jwt.py` script sets this automatically from `PUBLIC_URL` / `RAILWAY_PUBLIC_DOMAIN`.

### TRUSTED_DIDS configuration

For two Hermes agents to call each other, each must list the other's DID:

- **Agent A** env: `TRUSTED_DIDS=did:web:<agent-b-domain>`
- **Agent B** env: `TRUSTED_DIDS=did:web:<agent-a-domain>`

The DID is logged at startup and also available at `GET /.well-known/did.json` → `.id` field.

### Debugging auth errors

| Error | Cause | Fix |
|---|---|---|
| `403 Signature verification failed` | Custom JWT code used DER encoding | Call `generate_a2a_token()` — never write JWT signing code |
| `403 JWT missing iss claim` | `iss` omitted from JWT payload | Call `generate_a2a_token()` — never hand-craft the payload |
| `403 DID not trusted` | Caller's DID not in `TRUSTED_DIDS` | Add the caller's DID to the remote agent's `TRUSTED_DIDS` Railway variable |
| `404 on /token` | Remote agent has no `JWT_API_KEY` or `JWT_EXCHANGE_KEY` set | Use DID JWT path (Option B) or ask operator to set one of those vars |
