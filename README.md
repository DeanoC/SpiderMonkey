# SpiderMonkey

Spider Monkey is the standalone Spiderweb worker process and the new home for the extracted agent runtime. It does not talk to Spiderweb over a private RPC path. It is given a mounted Spiderweb workspace folder and uses the filesystem inside that mount as its contract.

## Manual V1 Flow

```bash
# 1. Build Spiderweb and Spider Monkey
cd /safe/Safe/wizball-codex/Spiderweb && zig build
cd /safe/Safe/wizball-codex/SpiderMonkey && zig build

# 2. Create a workspace in Spiderweb
/safe/Safe/wizball-codex/Spiderweb/zig-out/bin/spiderweb-control \
  --auth-token <token> \
  workspace_create \
  '{"name":"Demo","vision":"Track and deliver demo milestones"}'

# 3. Mount that workspace into the local filesystem
/safe/Safe/wizball-codex/Spiderweb/zig-out/bin/spiderweb-fs-mount \
  --workspace-url ws://127.0.0.1:18790/ \
  --workspace-id <workspace-id> \
  --workspace-token <workspace-token> \
  mount /mnt/spiderweb-demo

# 4. Start Spider Monkey in the mounted workspace
/safe/Safe/wizball-codex/SpiderMonkey/zig-out/bin/spider-monkey \
  run \
  --agent-id spider-monkey \
  --worker-id spider-monkey-a \
  --provider openai \
  --model gpt-4o-mini \
  --workspace-root /mnt/spiderweb-demo

# Optional: inspect the queue without processing jobs
/safe/Safe/wizball-codex/SpiderMonkey/zig-out/bin/spider-monkey \
  run \
  --workspace-root /mnt/spiderweb-demo \
  --once \
  --scan-only
```

## Current Behavior

- Validates the mounted workspace root exists.
- Claims a durable agent home through `/services/home` when that service is available and bootstraps `state`, `cache`, and `binds` directories under that home.
- Registers a worker-owned node through `/services/workers` when that service is available and claims private `memory` and `sub_brains` node paths for Spider Monkey.
- Refreshes that worker registration with filesystem heartbeats while the process is running so Spiderweb can mark the worker node live or stale.
- Writes a graceful detach request on normal shutdown so Spiderweb can remove the worker node immediately instead of waiting for lease reaping.
- Initializes the extracted provider-backed runtime locally and points it at Spider Monkey's own `templates/` and `agents/` content.
- Bridges runtime file tools onto the mounted Spiderweb workspace so canonical paths like `/services/...` operate against the mount root.
- Scans obvious Spiderweb roots such as `/services/chat`, `/services/jobs`, `/global/chat`, `/global/jobs`, and `/meta`.
- Enumerates `/services/jobs/<job-id>` directories, reads `status.json`, and shows an input preview from `request.json`.
- By default, processes queued jobs through the extracted runtime by writing `running`/`done`, filling `result.txt` and `log.txt`, and mirroring the latest reply into `chat/control/reply`.
- Marks jobs `failed` if runtime execution errors before a reply is produced.
- Supports `--scan-only` for a read-only inspection mode and `--once` for a single pass.
- Supports a polling loop with `--interval-ms`.
- Supports `--agent-id` to claim a stable per-agent home identity inside the workspace.
- Supports `--worker-id` to give the attached Spider Monkey process a stable worker-node identity inside the mounted workspace.
- Supports runtime config overrides with `--config`, `--provider`, `--model`, `--api-key`, `--base-url`, and `--emit-debug`.

## Verification

```bash
zig build
zig build test
```

`zig build` is the compile-time guard on the full extracted runtime path. The current `zig build test` step is intentionally scoped to SpiderMonkey-owned modules and filesystem path handling while the larger copied Spiderweb runtime suite is being brought across in follow-on slices.
