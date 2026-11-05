"""Exercise explain's behavior without relying on a submission's test names."""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


F2P_WEIGHTS = {
    "positional_shows_help": 0.5,
    "help_mentions_qualifier": 0.3,
    "stderr_hint": 0.2,
}


def run(command: list[str], cwd: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def excerpt(result: subprocess.CompletedProcess[str]) -> dict[str, object]:
    return {
        "returncode": result.returncode,
        "stdout_tail": result.stdout[-4000:],
        "stderr_tail": result.stderr[-4000:],
    }


def evaluate(repo: Path) -> tuple[dict[str, bool], dict[str, object]]:
    with tempfile.TemporaryDirectory(prefix="swt-explain-verifier-") as temporary:
        scratch = Path(temporary)
        binary = scratch / "entire"
        build = run(["go", "build", "-o", str(binary), "./cmd/entire"], repo, 600)
        gates = {name: False for name in (*F2P_WEIGHTS, "build_succeeds", "existing_tests_pass", "help_flag_works", "flags_intact")}
        evidence: dict[str, object] = {"build": excerpt(build)}
        gates["build_succeeds"] = build.returncode == 0
        if not gates["build_succeeds"]:
            return gates, evidence

        tests = run(["go", "test", "./cmd/entire/cli/", "-count=1"], repo, 600)
        gates["existing_tests_pass"] = tests.returncode == 0
        evidence["existing_tests"] = excerpt(tests)

        work = scratch / "repo"
        work.mkdir()
        init = run(["git", "init", "-q"], work, 30)
        if init.returncode != 0:
            evidence["git_init"] = excerpt(init)
            return gates, evidence

        bare = run([str(binary), "explain", "abc123"], work, 30)
        ordinary_help = run([str(binary), "explain", "--help"], work, 30)
        qualified = run([str(binary), "explain", "abc123", "--session", "missing-session"], work, 30)
        evidence.update(bare=excerpt(bare), ordinary_help=excerpt(ordinary_help), qualified=excerpt(qualified))

        gates["positional_shows_help"] = (
            bare.returncode == 0
            and "Usage:" in bare.stdout
            and "Usage:" not in qualified.stdout
            and "Hint:" not in qualified.stderr
        )
        gates["help_mentions_qualifier"] = all(
            flag in bare.stdout for flag in ("--session", "--commit", "--checkpoint")
        )
        gates["stderr_hint"] = (
            "Hint:" in bare.stderr
            and "Hint:" not in bare.stdout
            and "Hint:" not in ordinary_help.stdout
            and "Hint:" not in ordinary_help.stderr
            and "Hint:" not in qualified.stderr
        )
        gates["help_flag_works"] = (
            ordinary_help.returncode == 0 and "Usage:" in ordinary_help.stdout
        )
        gates["flags_intact"] = all(
            flag in ordinary_help.stdout for flag in ("--session", "--commit", "--checkpoint")
        )
        return gates, evidence


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path("/workspace/cli"))
    parser.add_argument("--logs", type=Path, default=Path("/logs/verifier"))
    parser.add_argument("--gate", choices=[*F2P_WEIGHTS, "build_succeeds", "existing_tests_pass", "help_flag_works", "flags_intact"])
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    try:
        gates, evidence = evaluate(args.repo)
    except (OSError, subprocess.TimeoutExpired) as error:
        gates = {name: False for name in (*F2P_WEIGHTS, "build_succeeds", "existing_tests_pass", "help_flag_works", "flags_intact")}
        evidence = {"verifier_error": f"{type(error).__name__}: {error}"}

    passed_p2p = all(gates[name] for name in ("build_succeeds", "existing_tests_pass", "help_flag_works", "flags_intact"))
    reward = sum(weight for name, weight in F2P_WEIGHTS.items() if gates[name]) if passed_p2p else 0.0
    report = {"gates": gates, "reward": reward, "evidence": evidence}
    (args.logs / "behavior_verifier.json").write_text(json.dumps(report, indent=2) + "\n")
    (args.logs / "reward.txt").write_text(f"{reward:.6f}\n")
    (args.logs / "gates.json").write_text(
        "".join(json.dumps({"id": name, "passed": passed}) + "\n" for name, passed in gates.items())
    )
    print(json.dumps({"gates": gates, "reward": reward}, sort_keys=True))
    if args.gate:
        return 0 if gates[args.gate] else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
