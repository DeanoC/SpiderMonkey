# Agent Management and Sub-Brains

Two namespaces cover agent topology management:

- `/services/agents` for agent inventory and creation when bound, otherwise the discovered agents service path
- `/nodes/<worker-id>/venoms/sub_brains` for worker-private sub-brain lifecycle
- `/services/workspaces` for workspace list/get/up lifecycle operations when bound, otherwise the discovered workspaces service path

Common operation mapping:

- `list`: read inventory/state
- `create` (agents): create a new managed agent workspace
- `upsert` (sub_brains): create or update a sub-brain config
- `delete` (sub_brains): remove a sub-brain config
- `up` (workspaces): create/update a workspace entry and optional activation settings

Capability and permission notes:

- Agent creation requires agent provisioning capability.
- Sub-brain mutations require sub-brain management capability.
- Always inspect `PERMISSIONS.json` and `CAPS.json` before mutations.

Safe mutation workflow:

1. List current state first.
2. Submit the narrowest mutation payload needed.
3. Check `status.json` then `result.json`.
4. Re-list to verify final state matches intent.

Avoid editing multiple management namespaces in one step unless the runtime and
policy explicitly guarantee ordering and rollback behavior.
