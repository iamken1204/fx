# De-Vercel Remainders

Fork spec for the `kfx` patch stack. Status: idea, not implemented. Nothing below exists in the tree.

Keep the Vercel code in the tree but off the execution path; deleting it would spread a thick patch across the hottest upstream files (`src/gateway/`, `session_usage.zig`, auth) and break the thin-patch strategy.

Most of it is already dormant through configuration:

- `credential_source: codex` idles the gateway transport, catalog, and credits accounting (the codex provider talks to `chatgpt.com/backend-api/codex` and shares no Vercel code).
- `FX_EXCLUDE_TOOLS` already suppresses the `gateway.perplexity_search` advertisement via `web_search`.
- The gateway-auxiliary vision fallback is gateway-only and never runs under codex.

What remains is cosmetic UX exposure, patch only if it bothers: the `fx login` menu still lists Vercel, and default model catalog surfaces may still mention gateway models. Dormant code costs binary size, not context or behavior.
