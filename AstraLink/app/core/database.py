from sqlalchemy import create_engine, inspect, text
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.core.config import get_settings


settings = get_settings()

connect_args: dict[str, object] = {}
if settings.database_url.startswith("sqlite"):
    connect_args = {"check_same_thread": False}

engine = create_engine(settings.database_url, future=True, connect_args=connect_args)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


def create_tables() -> None:
    from app.models import chat, customization, social, user  # noqa: F401

    Base.metadata.create_all(bind=engine)
    _apply_compat_migrations()


def _apply_compat_migrations() -> None:
    if not settings.database_url.startswith("sqlite"):
        return

    with engine.begin() as conn:
        inspector = inspect(conn)
        if "users" not in inspector.get_table_names():
            return

        columns = {column["name"] for column in inspector.get_columns("users")}
        if "uid" not in columns:
            conn.execute(text("ALTER TABLE users ADD COLUMN uid VARCHAR(40)"))
        conn.execute(text("CREATE UNIQUE INDEX IF NOT EXISTS ix_users_uid ON users (uid)"))
