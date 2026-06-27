"""Tests for the windows-branch intermediate anonymizer.

Reflects the unified API on the windows branch (``anonymize_path`` is an
alias of ``anonymize_text``). Prefix-stripping tests from ``main`` have been
removed because that behavior no longer exists. These are the tests the
agent finds on checkout — they are expected to pass against the buggy
intermediate code in ``windows_anonymizer.py``. New coverage for the
word-boundary / substring / Windows-backslash / custom-home / caching bugs
is what the agent is asked to add in later turns.
"""

from dataclaw.anonymizer import (
    Anonymizer,
    _hash_username,
    _replace_username,
    anonymize_path,
    anonymize_text,
)


HASH = "user_abc12345"


# ---------- _hash_username ----------

def test_hash_deterministic():
    assert _hash_username("alice") == _hash_username("alice")


def test_hash_format():
    h = _hash_username("alice")
    assert h.startswith("user_")
    assert len(h) == len("user_") + 8


def test_hash_differs_per_username():
    assert _hash_username("alice") != _hash_username("bob")


# ---------- anonymize_text: long usernames ----------

def test_long_username_plain_text():
    assert anonymize_text("Hello alice, how are you?", "alice", HASH) == \
        f"Hello {HASH}, how are you?"


def test_long_username_posix_path():
    assert anonymize_text("File at /Users/alice/project/main.py", "alice", HASH) == \
        f"File at /Users/{HASH}/project/main.py"


def test_long_username_home_path():
    assert anonymize_text("/home/alice/code", "alice", HASH) == f"/home/{HASH}/code"


def test_long_username_no_match_passthrough():
    assert anonymize_text("no username here", "alice", HASH) == "no username here"


def test_long_username_case_insensitive():
    result = anonymize_text("Hello Alice!", "alice", HASH)
    assert "Alice" not in result
    assert HASH in result


def test_empty_text():
    assert anonymize_text("", "alice", HASH) == ""


def test_empty_username():
    assert anonymize_text("some text", "", HASH) == "some text"


def test_long_username_multiple_occurrences():
    assert anonymize_text("alice and alice", "alice", HASH) == f"{HASH} and {HASH}"


# ---------- anonymize_text: short usernames (<4 chars) ----------

def test_short_username_posix_users_path():
    assert anonymize_text("/Users/bo/Documents/file.txt", "bo", HASH) == \
        f"/Users/{HASH}/Documents/file.txt"


def test_short_username_posix_home_path():
    assert anonymize_text("/home/bo/work", "bo", HASH) == f"/home/{HASH}/work"


def test_short_username_hyphen_encoded_path():
    # '-Users-bo-file' style paths (some loggers hyphen-encode paths)
    assert anonymize_text("-Users-bo-file", "bo", HASH) == f"-Users-{HASH}-file"


def test_short_username_outside_path_is_left_alone():
    # Short usernames should NOT be replaced in arbitrary text — too risky.
    assert anonymize_text("to be or not to be", "bo", HASH) == "to be or not to be"


# ---------- anonymize_path is an alias in the windows branch ----------

def test_anonymize_path_is_alias_of_text():
    assert anonymize_path is anonymize_text


def test_anonymize_path_behaves_like_text():
    assert anonymize_path("/Users/alice/x", "alice", HASH) == \
        anonymize_text("/Users/alice/x", "alice", HASH)


# ---------- _replace_username ----------

def test_replace_username_basic():
    assert _replace_username("hello alice", "alice", HASH) == f"hello {HASH}"


def test_replace_username_too_short_passthrough():
    # Usernames <3 chars should be left alone to avoid collateral damage.
    assert _replace_username("in the lab", "la", HASH) == "in the lab"


def test_replace_username_empty_text():
    assert _replace_username("", "alice", HASH) == ""


def test_replace_username_no_match():
    assert _replace_username("nothing here", "alice", HASH) == "nothing here"


# ---------- Anonymizer class ----------

def test_anonymizer_path_delegates_to_text():
    a = Anonymizer()
    # path() and text() should produce the same result for any input
    sample = "File at /Users/someone/project.py"
    assert a.path(sample) == a.text(sample)


def test_anonymizer_masks_detected_username(monkeypatch):
    monkeypatch.setattr(
        "dataclaw.anonymizer._detect_home_dir",
        lambda: ("/Users/alice", "alice"),
    )
    a = Anonymizer()
    assert "alice" not in a.text("hello alice")


def test_anonymizer_extra_usernames(monkeypatch):
    monkeypatch.setattr(
        "dataclaw.anonymizer._detect_home_dir",
        lambda: ("/Users/owner", "owner"),
    )
    a = Anonymizer(extra_usernames=["octocat"])
    out = a.text("ping octocat today")
    assert "octocat" not in out


def test_anonymizer_extra_usernames_too_short_ignored(monkeypatch):
    monkeypatch.setattr(
        "dataclaw.anonymizer._detect_home_dir",
        lambda: ("/Users/owner", "owner"),
    )
    a = Anonymizer(extra_usernames=["xy"])  # <3 chars: ignored
    assert a.text("xy stays") == "xy stays"


def test_anonymizer_skips_self_username(monkeypatch):
    monkeypatch.setattr(
        "dataclaw.anonymizer._detect_home_dir",
        lambda: ("/Users/alice", "alice"),
    )
    # Passing the detected username in extras should be a no-op (not double-hashed).
    a = Anonymizer(extra_usernames=["alice"])
    assert a.username_hash in a.text("hi alice")
