from functools import lru_cache
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Redis
    redis_url: str = "redis://redis:6379/0"

    # Session
    session_ttl_seconds:      int  = 3600
    session_cookie_name:      str  = "bashforge_session"
    max_concurrent_sessions:  int  = 50

    # AWS / ECS
    aws_region:           str        = "us-east-1"
    ecs_cluster:          str        = "bashforge"
    ecs_task_definition:  str        = "bashforge-sandbox"
    ecs_subnets:          list[str]  = []
    ecs_security_groups:  list[str]  = []

    # Security
    secure_cookies: bool = False

    # App
    cors_origins:   list[str] = ["http://localhost:3000"]
    debug:          bool      = False
    mock_ecs:         bool      = False
    mock_ws_token:    str       = "dev_token_not_secret"
    assign_public_ip: bool      = True


@lru_cache
def get_settings() -> Settings:
    return Settings()
