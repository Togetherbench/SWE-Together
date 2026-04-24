When replaying tool calls from the `github-copilot` backend to the `openai-codex` backend, the Codex API rejects the normalized function_call item IDs with an error like "contained additional characters".

Example: a Copilot-originated tool call has a raw ID like:
`call_4VnzVawQXPB9MgYib7CiQFEY|I9b95oN1wD/cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi...`

The `/`, `+`, `=` characters in the item-ID part get replaced with `_` during normalization, producing something like `fc_I9b95oN1wD_cHXKTw3PpRkL6KkCtzTJhUxMouMWYwHeTo2j3htzfSk7YPx2vi` — which the Codex backend rejects even though every individual character is valid.

The normalization logic is in `packages/ai/src/providers/openai-responses-shared.ts`. Fix it so that foreign tool call IDs (from a different provider than the target) are always safe for the target backend, deterministic (same input always produces same output), and within the 64-character limit.
