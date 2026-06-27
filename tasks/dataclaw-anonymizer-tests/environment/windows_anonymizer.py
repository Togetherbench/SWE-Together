"""Anonymize PII in Claude Code log data.

NOTE: This is the buggy intermediate state for the `windows` branch in the
Harbor task. It unifies ``anonymize_path`` into ``anonymize_text`` and adds
partial Windows support, but intentionally contains the bugs the agent is
expected to surface and fix:

  * ``\\b`` word boundaries — fails when the username is adjacent to an
    underscore (``config_alice_settings``).
  * ``re.sub`` is called with a fresh pattern on every call — no caching.
  * ``_replace_username`` does a plain ``str.replace`` — matches substrings,
    so ``alex`` also replaces inside ``alexis``.
  * No ``\\Users\\`` backslash support for short (<4 char) usernames.
  * ``home`` parameter is accepted but never used for custom home dirs.
  * No case-insensitive matching for short-username ``Users``/``home`` paths.
"""

import hashlib
import os
import re


def _hash_username(username: str) -> str:
    return "user_" + hashlib.sha256(username.encode()).hexdigest()[:8]


def _detect_home_dir() -> tuple[str, str]:
    home = os.path.expanduser("~")
    username = os.path.basename(home)
    return home, username


def anonymize_text(
    text: str,
    username: str,
    username_hash: str,
    home: str | None = None,
) -> str:
    if not text or not username:
        return text

    escaped = re.escape(username)

    if len(username) >= 4:
        # BUG: \b treats '_' as word char, so '_alice_' won't match.
        return re.sub(rf"\b{escaped}\b", username_hash, text)

    # Short username: handle POSIX-style /Users/<u> and /home/<u> paths only.
    # BUG: no \Users\ (Windows) support for short usernames; not case-insensitive.
    text = re.sub(
        rf"([/\-]+(?:Users|home)[/\-]+){escaped}(?=[^a-zA-Z0-9]|$)",
        rf"\g<1>{username_hash}",
        text,
    )
    # BUG: home parameter is accepted but never applied.
    return text


# Backward compatibility — windows branch unifies path handling into text.
anonymize_path = anonymize_text


class Anonymizer:
    """Stateful anonymizer that consistently hashes usernames."""

    def __init__(self, extra_usernames: list[str] | None = None):
        self.home, self.username = _detect_home_dir()
        self.username_hash = _hash_username(self.username)

        self._extra: list[tuple[str, str]] = []
        for name in extra_usernames or []:
            name = name.strip()
            if name and name != self.username and len(name) >= 3:
                self._extra.append((name, _hash_username(name)))

    def path(self, file_path: str) -> str:
        return self.text(file_path)

    def text(self, content: str) -> str:
        result = anonymize_text(content, self.username, self.username_hash, self.home)
        for name, hashed in self._extra:
            result = _replace_username(result, name, hashed)
        return result


def _replace_username(text: str, username: str, username_hash: str) -> str:
    if not text or not username or len(username) < 3:
        return text
    # BUG: naive substring replace — replaces 'alex' inside 'alexis'.
    return text.replace(username, username_hash)
