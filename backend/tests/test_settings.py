import pytest
from pydantic import ValidationError

from app.core.settings import load_settings


def test_defaults_need_no_environment() -> None:
    settings = load_settings({})

    assert settings.environment == "development"
    assert settings.log_level == "INFO"


def test_reads_upper_case_environment_variables() -> None:
    settings = load_settings({"ENVIRONMENT": "production", "LOG_LEVEL": "WARNING"})

    assert settings.environment == "production"
    assert settings.log_level == "WARNING"


@pytest.mark.parametrize(
    ("name", "value"),
    [("ENVIRONMENT", "staging-typo"), ("LOG_LEVEL", "LOUD")],
)
def test_invalid_values_fail_naming_the_setting(name: str, value: str) -> None:
    with pytest.raises(ValidationError) as excinfo:
        load_settings({name: value})

    assert name.lower() in str(excinfo.value)
