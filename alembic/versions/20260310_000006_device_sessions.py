"""device sessions metadata on refresh tokens

Revision ID: 20260310_000006
Revises: 20260310_000005
Create Date: 2026-03-10 18:20:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260310_000006"
down_revision: str | None = "20260310_000005"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


def _column_names(bind, table_name: str) -> set[str]:
    return {column["name"] for column in sa.inspect(bind).get_columns(table_name)}


def _index_names(bind, table_name: str) -> set[str]:
    return {index["name"] for index in sa.inspect(bind).get_indexes(table_name)}


def upgrade() -> None:
    bind = op.get_bind()
    refresh_columns = _column_names(bind, "refresh_tokens")
    refresh_indexes = _index_names(bind, "refresh_tokens")

    with op.batch_alter_table("refresh_tokens") as batch_op:
        if "session_key" not in refresh_columns:
            batch_op.add_column(
                sa.Column("session_key", sa.String(length=64), nullable=False, server_default="")
            )
        if "device_name" not in refresh_columns:
            batch_op.add_column(sa.Column("device_name", sa.String(length=120), nullable=True))
        if "platform" not in refresh_columns:
            batch_op.add_column(sa.Column("platform", sa.String(length=40), nullable=True))
        if "user_agent" not in refresh_columns:
            batch_op.add_column(sa.Column("user_agent", sa.String(length=255), nullable=True))
        if "ip_address" not in refresh_columns:
            batch_op.add_column(sa.Column("ip_address", sa.String(length=64), nullable=True))
        if "ix_refresh_tokens_session_key" not in refresh_indexes:
            batch_op.create_index("ix_refresh_tokens_session_key", ["session_key"], unique=False)
        if "session_key" not in refresh_columns:
            batch_op.alter_column("session_key", server_default=None)

    refresh_tokens = sa.table(
        "refresh_tokens",
        sa.column("id", sa.Integer()),
        sa.column("session_key", sa.String(length=64)),
    )
    rows = list(bind.execute(sa.select(refresh_tokens.c.id, refresh_tokens.c.session_key)))
    for row in rows:
        current_key = (row.session_key or "").strip()
        if current_key:
            continue
        bind.execute(
            refresh_tokens.update()
            .where(refresh_tokens.c.id == row.id)
            .values(session_key=f"legacy-{row.id}")
        )


def downgrade() -> None:
    bind = op.get_bind()
    refresh_columns = _column_names(bind, "refresh_tokens")
    refresh_indexes = _index_names(bind, "refresh_tokens")

    with op.batch_alter_table("refresh_tokens") as batch_op:
        if "ix_refresh_tokens_session_key" in refresh_indexes:
            batch_op.drop_index("ix_refresh_tokens_session_key")
        if "ip_address" in refresh_columns:
            batch_op.drop_column("ip_address")
        if "user_agent" in refresh_columns:
            batch_op.drop_column("user_agent")
        if "platform" in refresh_columns:
            batch_op.drop_column("platform")
        if "device_name" in refresh_columns:
            batch_op.drop_column("device_name")
        if "session_key" in refresh_columns:
            batch_op.drop_column("session_key")
