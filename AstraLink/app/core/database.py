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
    from app.models import chat, user  # noqa: F401

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
        if "phone" not in columns:
            conn.execute(text("ALTER TABLE users ADD COLUMN phone VARCHAR(24)"))
        if "first_name" not in columns:
            conn.execute(text("ALTER TABLE users ADD COLUMN first_name VARCHAR(80) DEFAULT ''"))
        if "last_name" not in columns:
            conn.execute(text("ALTER TABLE users ADD COLUMN last_name VARCHAR(80) DEFAULT ''"))
        conn.execute(text("CREATE UNIQUE INDEX IF NOT EXISTS ix_users_uid ON users (uid)"))
        conn.execute(text("CREATE UNIQUE INDEX IF NOT EXISTS ix_users_phone ON users (phone)"))

        if "chat_members" in inspector.get_table_names():
            member_columns = {column["name"] for column in inspector.get_columns("chat_members")}
            if "is_archived" not in member_columns:
                conn.execute(text("ALTER TABLE chat_members ADD COLUMN is_archived BOOLEAN DEFAULT 0"))
            if "is_pinned" not in member_columns:
                conn.execute(text("ALTER TABLE chat_members ADD COLUMN is_pinned BOOLEAN DEFAULT 0"))
            if "folder" not in member_columns:
                conn.execute(text("ALTER TABLE chat_members ADD COLUMN folder VARCHAR(32)"))

            conn.execute(text("CREATE INDEX IF NOT EXISTS ix_chat_members_is_archived ON chat_members (is_archived)"))
            conn.execute(text("CREATE INDEX IF NOT EXISTS ix_chat_members_is_pinned ON chat_members (is_pinned)"))
            conn.execute(text("CREATE INDEX IF NOT EXISTS ix_chat_members_folder ON chat_members (folder)"))
