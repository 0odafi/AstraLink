from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "AstraLink API"
    environment: str = "development"
    secret_key: str = "change-this-in-production"
    access_token_expire_minutes: int = 60 * 24 * 7
    refresh_token_expire_days: int = 90
    database_url: str = "sqlite:///./astralink.db"
    cors_origins: str = "*"
    release_manifest_path: str = "./releases/manifest.json"

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    @property
    def cors_origin_list(self) -> list[str]:
        if self.cors_origins.strip() == "*":
            return ["*"]
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
