Implement the following plan:

# Fix overlapping lock coordinator race (Issue #865)

## Context

When two LCM config entries share the same lock (e.g., "All Locks" with slots 11-14 and "Front Door" with slots 1-6, both managing `lock.f`), startup produces:

1. **"Coordinator missing for lock X when adding slot Y entities"** warnings — entities for the second config entry are never created, leaving them unavailable until reload
2. **"Unable to remove unknown job listener"** error on reload — the `_on_started` one-time listener has already auto-removed itself, but unload tries to remove it again

### Root cause

**Coordinator missing**: During HA startup, both entries register `_on_started` listeners. When `EVENT_HOMEASSISTANT_STARTED` fires, both `async_update_listener` tasks run concurrently. Entry A creates the lock instance (stored in the global dict at `__init__.py:499` **before** the `await`), then starts `await lock.async_setup()`. Entry B finds the lock in the global dict (line 488), reuses it, but **skips** `async_setup` entirely. It immediately invokes `add_code_slot_entities` callbacks — which check `lock.coordinator is None` → warning, no entities created.

**Listener error**: `async_listen_once` auto-removes the `_on_started` callback after it fires. On reload/unload, `_safe_unsub()` calls `unsub()` which hits `_async_remove_listener` — HA core logs an ERROR before raising ValueError. The `_safe_unsub` catches the ValueError, but the error log has already been emitted.

## Changes

### 1. `providers/_base.py` — Add setup gate

Add an `asyncio.Event` field to `BaseLock` that signals when `async_setup` completes, so concurrent callers can wait:

```python
_setup_complete: asyncio.Event = field(default_factory=asyncio.Event, init=False)
```

At the end of `async_setup()`, after coordinator creation and push subscription, call:
```python
self._setup_complete.set()
```

Also set it in the early-return path (coordinator already exists, line 307-312) so re-setup calls don't block.

### 2. `__init__.py` — Wait for setup on lock reuse

In `async_update_listener()`, when a lock instance is reused (line 488-496), wait for its setup to complete before creating entities:

```python
if lock_entity_id in hass_data[CONF_LOCKS]:
    lock = runtime_data.locks[lock_entity_id] = hass_data[CONF_LOCKS][lock_entity_id]
    await lock._setup_complete.wait()  # <-- ADD THIS
else:
    ...
```

This is a no-op if setup already completed (Event is already set), and blocks correctly if another entry's `async_update_listener` is still running `async_setup()`.

### 3. `__init__.py` — Fix listener unsubscribe error

In `async_setup_entry()`, track whether `_on_started` has fired and skip the unsub if it has:

```python
started = False

@callback
def _on_started(event: Event) -> None:
    nonlocal started
    started = True
    _setup_entry_after_start(hass, config_entry, event)

unsub = hass.bus.async_listen_once(EVENT_HOMEASSISTANT_STARTED, _on_started)

@callback
def _safe_unsub() -> None:
    if not started:
        unsub()

config_entry.async_on_unload(_safe_unsub)
```

### 4. Tests

Add tests in `tests/test_init.py` (or a new `tests/test_overlapping_locks.py` if cleaner):

1. **`test_overlapping_locks_both_entries_get_entities`** — Two config entries sharing a lock, both set up during startup. Verify both entries create their binary_sensor and sensor entities (no "Coordinator missing" warnings).
2. **`test_overlapping_locks_reload_no_listener_error`** — Two config entries sharing a lock, reload one. Verify no "Unable to remove unknown job listener" error.
3. **`test_setup_complete_event_set_after_setup`** — Verify `_setup_complete` is set after `async_setup` completes.

## Files Modified

- `custom_components/lock_code_manager/providers/_base.py` — `_setup_complete` event field + set it in `async_setup`
- `custom_components/lock_code_manager/__init__.py` — `await lock._setup_complete.wait()` on reuse + fix `_safe_unsub`
- `tests/test_init.py` (or new test file) — new tests

## Verification

1. `uv run pytest tests/ -x` — all tests pass
2. `uv run pre-commit run --all-files` — linting passes


If you need specific details from before exiting plan mode (like exact code snippets, error messages, or content you generated), read the full transcript at: /Users/raman/.claude/projects/-Users-raman-projects-lock-code-manager/b1386405-5f79-42e9-a9bf-25375841c5d0.jsonl
