# Venom Discovery

Start at:

- `/meta/workspace_services.json`
- `/meta/venom_packages.json`
- `/projects/<workspace_id>/meta/mounted_services.json`
- `/nodes/local/venoms/VENOMS.json`
- `/global/venoms/VENOMS.json`

`workspace_services.json` provides effective mounted service paths for the current workspace.

`venom_packages.json` provides package metadata:

- `venom_id`
- `kind`
- `categories`
- `hosts`
- `projection_modes`
- `requirements`

`VENOMS.json` entries provide live instance details:

- `node_id`
- `venom_id`
- `venom_path`
- `invoke_path`
- `has_invoke`
- `scope` (`node` | `project_namespace` | `global_namespace`)

Scope guidance:

- `project_namespace`: workspace-shared services under `/global/*`
- `node`: node/device Venoms under `/nodes/<node_id>/venoms/*`
- `global_namespace`: shared global resources under `/global/*`

Contract check workflow:

1. Read `/meta/workspace_services.json`.
2. If needed, read `/meta/venom_packages.json` for requirements and category hints.
3. Select a candidate service or Venom instance.
4. Read contract files under the service path or `venom_path`:
   - `README.md`
   - `SCHEMA.json`
   - `CAPS.json`
   - `OPS.json`
   - `PERMISSIONS.json`
   - optional: `RUNTIME.json`, `MOUNTS.json`, `STATUS.json`
5. If `has_invoke=true`, write to `invoke_path`.
6. Read Venom `status.json` and `result.json`.

Example: invoke terminal

1. Read `/meta/workspace_services.json`.
2. Select the `terminal` service path.
3. Read `/services/terminal/SCHEMA.json`.
4. Write:
   - path: `/services/terminal/control/invoke.json`
   - payload: `{"op":"exec","arguments":{"command":"pwd"}}`
5. Read:
   - `/services/terminal/status.json`
   - `/services/terminal/result.json`

Quick roots:

- `/services/web_search`
- `/services/search_code`
- `/services/terminal`
- `/services/mounts`
- `/services/agents`
- `/services/workspaces`
- `/global/library`
- `/nodes/<worker-id>/venoms/memory`
- `/nodes/<worker-id>/venoms/sub_brains`

Node-scoped discovery root:

- `/nodes/<node_id>/venoms/<venom_id>`
