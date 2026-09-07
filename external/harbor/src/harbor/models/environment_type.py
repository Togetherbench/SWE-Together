from enum import Enum


class EnvironmentType(str, Enum):
    DOCKER = "docker"
    DAYTONA = "daytona"
    E2B = "e2b"
    MODAL = "modal"
    RUNLOOP = "runloop"
    GKE = "gke"
    APPLE_CONTAINER = "apple-container"
    # SWE-Together addition: enroot containers on Slurm compute nodes. Not in
    # EnvironmentFactory._ENVIRONMENTS; selected via EnvironmentConfig.import_path
    # (src/enroot_backend/environment.py).
    ENROOT = "enroot"
