import os
from collections.abc import Mapping
from typing import Literal

from pydantic import BaseModel, ConfigDict


class Settings(BaseModel):
    """Settings validated at startup. P0 needs no database, Auth, TMDB or AI configuration."""

    model_config = ConfigDict(frozen=True)

    environment: Literal["development", "test", "production"] = "development"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"


def load_settings(env: Mapping[str, str] = os.environ) -> Settings:
    """Read settings from environment variables named after the fields in upper case."""
    values = {name: env[name.upper()] for name in Settings.model_fields if name.upper() in env}
    return Settings.model_validate(values)
