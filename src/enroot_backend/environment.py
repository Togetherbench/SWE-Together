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
"""

from __future__ import annotations

from pathlib import Path

from dockerfile_parse import DockerfileParser

from harbor.environments.base import BaseEnvironment, ExecResult
from harbor.models.environment_type import EnvironmentType
from harbor.models.task.config import EnvironmentConfig
from harbor.models.trial.paths import EnvironmentPaths, TrialPaths

from .container import EnrootContainer
from .images import ImageStore, image_id
from .runtime import EnrootRuntime, EnrootSetupError

IMPORT_PATH = "enroot_backend.environment:EnrootEnvironment"


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
        return False

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

        self._container = EnrootContainer(
            self._runtime, sqsh,
            name_hint=self.environment_name,
            workdir=self._workdir,
            mounts=mounts,
            persist_tmp=self._persist_tmp,
        )
        await self._container.create()

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
