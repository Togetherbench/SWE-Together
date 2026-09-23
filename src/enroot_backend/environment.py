"""Harbor ``BaseEnvironment`` backed by an enroot container.

Selected from ``src/run_eval.py`` via::

    EnvironmentConfig(
        import_path="enroot_backend.environment:EnrootEnvironment",
        kwargs={"image_store_root": ..., "hosts_file": ...},
    )

``is_mounted`` is True: ``trial_dir/{agent,verifier,artifacts}`` are bind-mounted
to ``/logs/{agent,verifier,artifacts}`` so Harbor skips post-hoc downloads and
logs are live on Lustre. ``/tmp`` is a per-container persistent directory and the
generated DNS-sinkhole hosts file is mounted over ``/etc/hosts``.

With ``egress_sock`` set, the container runs in its own network namespace and
reaches the network only through the host-side egress proxy listening on that
unix socket (``netns.py``, ``proxies/egress_proxy.py``). A self-test runs before
the agent's first command and the trial aborts if enforcement is not in place.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from dockerfile_parse import DockerfileParser

from harbor.environments.base import BaseEnvironment, ExecResult
from harbor.models.environment_type import EnvironmentType
from harbor.models.task.config import EnvironmentConfig
from harbor.models.trial.paths import EnvironmentPaths, TrialPaths

from .container import EnrootContainer
from .images import ImageStore, image_id
from .netns import EgressNamespace, ca_install_script, evaluate_selftest, selftest_script, write_selftest_result
from .runtime import EnrootRuntime, EnrootSetupError

IMPORT_PATH = "enroot_backend.environment:EnrootEnvironment"
SELFTEST_FILE = "egress_selftest.json"
SELFTEST_TIMEOUT_S = 120.0


class EnrootEnvironment(BaseEnvironment):
    def __init__(
        self,
        environment_dir: Path,
        environment_name: str,
        session_id: str,
        trial_paths: TrialPaths,
        task_env_config: EnvironmentConfig,
        image_store_root: str | None = None,
        hosts_file: str | None = None,
        persist_tmp: bool = True,
        enroot_base: str | None = None,
        egress_sock: str | None = None,
        egress_ca: str | None = None,
        *args,
        **kwargs,
    ):
        super().__init__(
            environment_dir=environment_dir,
            environment_name=environment_name,
            session_id=session_id,
            trial_paths=trial_paths,
            task_env_config=task_env_config,
            **kwargs,
        )
        self._store = ImageStore(root=image_store_root)
        self._hosts_file = Path(hosts_file) if hosts_file else None
        self._persist_tmp = persist_tmp
        self._runtime = EnrootRuntime(base=enroot_base)
        self._egress_sock = Path(egress_sock) if egress_sock else None
        self._egress_ca = Path(egress_ca) if egress_ca else None
        self._container: EnrootContainer | None = None

        dockerfile = self.environment_dir / "Dockerfile"
        self._workdir = "/"
        if dockerfile.exists():
            self._workdir = next(
                (
                    instruction["value"]
                    for instruction in reversed(DockerfileParser(path=str(dockerfile)).structure)
                    if instruction.get("instruction") == "WORKDIR"
                ),
                "/",
            )

    @staticmethod
    def type() -> EnvironmentType:
        return EnvironmentType.ENROOT

    @property
    def is_mounted(self) -> bool:
        return True

    @property
    def supports_gpus(self) -> bool:
        return False

    @property
    def can_disable_internet(self) -> bool:
        return self._egress_sock is not None

    @property
    def egress_enforced(self) -> bool:
        return self._egress_sock is not None

    def _validate_definition(self):
        if not self.task_env_config.docker_image:
            raise FileNotFoundError(
                f"{self.environment_name}: task.toml has no [environment].docker_image; "
                "the enroot backend needs a prebuilt image (it cannot build Dockerfiles)."
            )

    def _require(self) -> EnrootContainer:
        if self._container is None:
            raise RuntimeError("Container not started. Call start() first.")
        return self._container

    async def start(self, force_build: bool):
        if force_build:
            self.logger.warning(
                "force_build is a no-op for enroot; delete the .sqsh in the image store "
                "to force a re-import."
            )
        image = self.task_env_config.docker_image
        assert image
        if not self._store.has(image_id(image)):
            self.logger.warning(
                "%s not in image store; importing on demand (pre-pull with "
                "`launch.py prepull` to avoid this)", image,
            )
        sqsh = self._store.ensure_image(image)

        for d in (self.trial_paths.agent_dir, self.trial_paths.verifier_dir,
                  self.trial_paths.artifacts_dir):
            d.mkdir(parents=True, exist_ok=True)
        mounts: list[tuple[str | Path, str]] = [
            (self.trial_paths.agent_dir, str(EnvironmentPaths.agent_dir)),
            (self.trial_paths.verifier_dir, str(EnvironmentPaths.verifier_dir)),
            (self.trial_paths.artifacts_dir, str(EnvironmentPaths.artifacts_dir)),
        ]
        if self._hosts_file is not None:
            if not self._hosts_file.is_file():
                raise EnrootSetupError(f"hosts file not found: {self._hosts_file}")
            mounts.append((self._hosts_file, "/etc/hosts"))

        egress = None
        if self._egress_sock is not None:
            egress = EgressNamespace(
                container_name=self.environment_name,
                sock_path=self._egress_sock,
                relay_script=self._runtime.root / "egress_relay.py",
                meta={
                    "trial": self.session_id,
                    "log": str(self.trial_paths.agent_dir / "egress.log"),
                    "task_dir": str(self.environment_dir.parent),
                },
                log_dir=self._runtime.root / "relay-logs",
                python=sys.executable,
            )

        self._container = EnrootContainer(
            self._runtime, sqsh,
            name_hint=self.environment_name,
            workdir=self._workdir,
            mounts=mounts,
            persist_tmp=self._persist_tmp,
            egress=egress,
        )
        await self._container.create()
        if egress is not None:
            await self._install_egress_ca()
            await self._scan_workspace_packages(egress)
            await self._egress_selftest()

    async def _install_egress_ca(self) -> None:
        """Copy the per-job CA into the rootfs and build the trust bundle the env points at."""
        if self._egress_ca is None or not self._egress_ca.is_file():
            raise EnrootSetupError(f"egress CA certificate missing: {self._egress_ca}")
        import egress_policy
        container = self._require()
        container.copy_in(self._egress_ca, egress_policy.CA_CERT_PATH)
        res = await container.exec(ca_install_script(), cwd="/", timeout=60)
        if res.return_code != 0 or "ca_bundle_ok" not in res.stdout:
            raise EnrootSetupError(f"egress CA install failed for {self.session_id}: {(res.stderr or res.stdout)[-300:]}")

    async def _scan_workspace_packages(self, egress: EgressNamespace) -> None:
        """List the workspace's own package names and hand them to the proxy as a denylist."""
        import egress_policy
        container = self._require()
        res = await container.exec(egress_policy.workspace_packages_script(self._workdir), cwd="/", timeout=120)
        if "SWT_PKGSCAN_DONE" not in res.stdout:
            raise EnrootSetupError(
                f"workspace package scan did not complete for {self.session_id} (rc={res.return_code}): "
                f"{(res.stderr or res.stdout)[-200:]}"
            )
        pkgs = egress_policy.parse_workspace_packages(res.stdout)
        (self.trial_paths.agent_dir / "egress_task_packages.json").write_text(json.dumps(pkgs, indent=1) + "\n")
        egress.update_meta(deny_packages=pkgs)
        self.logger.info("egress: denying registry access to %d npm / %d PyPI / %d crate names of the workspace",
                         len(pkgs.get("npm", [])), len(pkgs.get("pypi", [])), len(pkgs.get("crates", [])))

    async def _egress_selftest(self) -> None:
        """Prove, from inside this container, that only the proxy path exists.

        Written to ``agent/egress_selftest.json``; a failure aborts the trial before
        the agent runs (the sentinel maps it to ``infra_failed``), never runs porous.
        """
        container = self._require()
        res = await container.exec(selftest_script(), cwd="/", timeout=SELFTEST_TIMEOUT_S)
        result = evaluate_selftest(res.stdout)
        result["exec_rc"] = res.return_code
        result["stderr_tail"] = res.stderr[-500:]
        if container.egress is not None:
            result["namespace"] = container.egress.describe()
        write_selftest_result(self.trial_paths.agent_dir / SELFTEST_FILE, result)
        if not result["ok"]:
            failed = [k for k, v in result["checks"].items() if not v]
            raise EnrootSetupError(
                f"egress self-test failed for {self.session_id}: {failed}; raw={json.dumps(result['raw'])[:300]}"
            )
        self.logger.info("egress self-test passed for %s", self.session_id)

    async def stop(self, delete: bool):
        if not delete:
            self.logger.info(
                "enroot containers live on tmpfs and are removed after use "
                "regardless of delete=False."
            )
        if self._container is not None:
            await self._container.remove()
            self._container = None

    async def upload_file(self, source_path: Path | str, target_path: str):
        self._require().copy_in(source_path, target_path)

    async def upload_dir(self, source_dir: Path | str, target_dir: str):
        self._require().copy_in_dir(source_dir, target_dir)

    async def download_file(self, source_path: str, target_path: Path | str):
        self._require().copy_out(source_path, target_path)

    async def download_dir(self, source_dir: str, target_dir: Path | str):
        self._require().copy_out_dir(source_dir, target_dir)

    async def is_dir(self, path: str) -> bool:
        return self._require().host_path(path).is_dir()

    async def is_file(self, path: str) -> bool:
        return self._require().host_path(path).is_file()

    async def exec(
        self,
        command: str,
        cwd: str | None = None,
        env: dict[str, str] | None = None,
        timeout_sec: int | None = None,
    ) -> ExecResult:
        res = await self._require().exec(
            command, cwd=cwd, env=self._merge_env(env),
            timeout=float(timeout_sec) if timeout_sec else None,
        )
        return ExecResult(stdout=res.stdout, stderr=res.stderr, return_code=res.return_code)
