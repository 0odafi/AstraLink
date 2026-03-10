"""media metadata, privacy settings, and block lists

Revision ID: 20260309_000004
Revises: 20260309_000003
Create Date: 2026-03-10 01:15:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision: str = "20260309_000004"
down_revision: str | None = "20260309_000003"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


media_kind = postgresql.ENUM("file", "image", "video", "audio", "voice", name="mediakind")
media_kind_reuse = postgresql.ENUM(
    "file",
    "image",
    "video",
    "audio",
    "voice",
    name="mediakind",
    create_type=False,
)
privacy_audience = postgresql.ENUM("everyone", "contacts", "nobody", name="privacyaudience")
privacy_audience_reuse = postgresql.ENUM(
    "everyone",
    "contacts",
    "nobody",
    name="privacyaudience",
    create_type=False,
)


def _table_names(bind) -> set[str]:
    return set(sa.inspect(bind).get_table_names())


def _column_names(bind, table_name: str) -> set[str]:
    return {column["name"] for column in sa.inspect(bind).get_columns(table_name)}


def _index_names(bind, table_name: str) -> set[str]:
    return {index["name"] for index in sa.inspect(bind).get_indexes(table_name)}


def upgrade() -> None:
    bind = op.get_bind()
    media_kind.create(bind, checkfirst=True)
    privacy_audience.create(bind, checkfirst=True)

    tables = _table_names(bind)

    if "users" in tables:
        user_columns = _column_names(bind, "users")
        user_indexes = _index_names(bind, "users")
        with op.batch_alter_table("users") as batch_op:
            if "last_seen_at" not in user_columns:
                batch_op.add_column(sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=True))
            if "ix_users_last_seen_at" not in user_indexes:
                batch_op.create_index("ix_users_last_seen_at", ["last_seen_at"], unique=False)

    if "media_files" in tables:
        media_columns = _column_names(bind, "media_files")
        media_indexes = _index_names(bind, "media_files")
        with op.batch_alter_table("media_files") as batch_op:
            if "media_kind" not in media_columns:
                batch_op.add_column(
                    sa.Column("media_kind", media_kind_reuse, nullable=False, server_default="file")
                )
            if "sha256" not in media_columns:
                batch_op.add_column(sa.Column("sha256", sa.String(length=64), nullable=True))
            if "width" not in media_columns:
                batch_op.add_column(sa.Column("width", sa.Integer(), nullable=True))
            if "height" not in media_columns:
                batch_op.add_column(sa.Column("height", sa.Integer(), nullable=True))
            if "duration_seconds" not in media_columns:
                batch_op.add_column(sa.Column("duration_seconds", sa.Integer(), nullable=True))
            if "thumbnail_storage_name" not in media_columns:
                batch_op.add_column(sa.Column("thumbnail_storage_name", sa.String(length=255), nullable=True))
            if "ix_media_files_media_kind" not in media_indexes:
                batch_op.create_index("ix_media_files_media_kind", ["media_kind"], unique=False)

        media_columns = _column_names(bind, "media_files")
        if "media_kind" in media_columns:
            op.execute("UPDATE media_files SET media_kind = 'image' WHERE mime_type LIKE 'image/%' AND media_kind = 'file'")
            op.execute("UPDATE media_files SET media_kind = 'video' WHERE mime_type LIKE 'video/%' AND media_kind = 'file'")
            op.execute("UPDATE media_files SET media_kind = 'audio' WHERE mime_type LIKE 'audio/%' AND media_kind = 'file'")
            with op.batch_alter_table("media_files") as batch_op:
                batch_op.alter_column("media_kind", server_default=None)

    if "user_privacy_settings" not in tables:
        op.create_table(
            "user_privacy_settings",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("phone_visibility", privacy_audience_reuse, nullable=False, server_default="everyone"),
            sa.Column("phone_search_visibility", privacy_audience_reuse, nullable=False, server_default="everyone"),
            sa.Column("last_seen_visibility", privacy_audience_reuse, nullable=False, server_default="everyone"),
            sa.Column("show_approximate_last_seen", sa.Boolean(), nullable=False, server_default=sa.true()),
            sa.Column("allow_group_invites", privacy_audience_reuse, nullable=False, server_default="everyone"),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
            sa.UniqueConstraint("user_id", name="uq_user_privacy_settings_user"),
        )
    if "user_privacy_settings" in _table_names(bind):
        privacy_indexes = _index_names(bind, "user_privacy_settings")
        if "ix_user_privacy_settings_user_id" not in privacy_indexes:
            op.create_index("ix_user_privacy_settings_user_id", "user_privacy_settings", ["user_id"], unique=True)

    if "user_data_settings" not in tables:
        op.create_table(
            "user_data_settings",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("keep_media_days", sa.Integer(), nullable=False, server_default="30"),
            sa.Column("storage_limit_mb", sa.Integer(), nullable=False, server_default="2048"),
            sa.Column("auto_download_photos", sa.Boolean(), nullable=False, server_default=sa.true()),
            sa.Column("auto_download_videos", sa.Boolean(), nullable=False, server_default=sa.true()),
            sa.Column("auto_download_music", sa.Boolean(), nullable=False, server_default=sa.true()),
            sa.Column("auto_download_files", sa.Boolean(), nullable=False, server_default=sa.false()),
            sa.Column("default_auto_delete_seconds", sa.Integer(), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
            sa.UniqueConstraint("user_id", name="uq_user_data_settings_user"),
        )
    if "user_data_settings" in _table_names(bind):
        data_indexes = _index_names(bind, "user_data_settings")
        if "ix_user_data_settings_user_id" not in data_indexes:
            op.create_index("ix_user_data_settings_user_id", "user_data_settings", ["user_id"], unique=True)

    if "blocked_users" not in tables:
        op.create_table(
            "blocked_users",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("blocker_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("blocked_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.UniqueConstraint("blocker_id", "blocked_id", name="uq_blocked_user_pair"),
        )
    if "blocked_users" in _table_names(bind):
        blocked_indexes = _index_names(bind, "blocked_users")
        if "ix_blocked_users_blocker_id" not in blocked_indexes:
            op.create_index("ix_blocked_users_blocker_id", "blocked_users", ["blocker_id"], unique=False)
        if "ix_blocked_users_blocked_id" not in blocked_indexes:
            op.create_index("ix_blocked_users_blocked_id", "blocked_users", ["blocked_id"], unique=False)


def downgrade() -> None:
    bind = op.get_bind()

    if "blocked_users" in _table_names(bind):
        blocked_indexes = _index_names(bind, "blocked_users")
        if "ix_blocked_users_blocked_id" in blocked_indexes:
            op.drop_index("ix_blocked_users_blocked_id", table_name="blocked_users")
        if "ix_blocked_users_blocker_id" in blocked_indexes:
            op.drop_index("ix_blocked_users_blocker_id", table_name="blocked_users")
        op.drop_table("blocked_users")

    if "user_data_settings" in _table_names(bind):
        data_indexes = _index_names(bind, "user_data_settings")
        if "ix_user_data_settings_user_id" in data_indexes:
            op.drop_index("ix_user_data_settings_user_id", table_name="user_data_settings")
        op.drop_table("user_data_settings")

    if "user_privacy_settings" in _table_names(bind):
        privacy_indexes = _index_names(bind, "user_privacy_settings")
        if "ix_user_privacy_settings_user_id" in privacy_indexes:
            op.drop_index("ix_user_privacy_settings_user_id", table_name="user_privacy_settings")
        op.drop_table("user_privacy_settings")

    if "media_files" in _table_names(bind):
        media_columns = _column_names(bind, "media_files")
        media_indexes = _index_names(bind, "media_files")
        with op.batch_alter_table("media_files") as batch_op:
            if "ix_media_files_media_kind" in media_indexes:
                batch_op.drop_index("ix_media_files_media_kind")
            if "thumbnail_storage_name" in media_columns:
                batch_op.drop_column("thumbnail_storage_name")
            if "duration_seconds" in media_columns:
                batch_op.drop_column("duration_seconds")
            if "height" in media_columns:
                batch_op.drop_column("height")
            if "width" in media_columns:
                batch_op.drop_column("width")
            if "sha256" in media_columns:
                batch_op.drop_column("sha256")
            if "media_kind" in media_columns:
                batch_op.drop_column("media_kind")

    if "users" in _table_names(bind):
        user_columns = _column_names(bind, "users")
        user_indexes = _index_names(bind, "users")
        with op.batch_alter_table("users") as batch_op:
            if "ix_users_last_seen_at" in user_indexes:
                batch_op.drop_index("ix_users_last_seen_at")
            if "last_seen_at" in user_columns:
                batch_op.drop_column("last_seen_at")

    privacy_audience.drop(bind, checkfirst=True)
    media_kind.drop(bind, checkfirst=True)
