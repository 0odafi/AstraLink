"""scheduled messages

Revision ID: 20260310_000005
Revises: 20260309_000004
Create Date: 2026-03-10 15:10:00
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "20260310_000005"
down_revision: str | None = "20260309_000004"
branch_labels: Sequence[str] | None = None
depends_on: Sequence[str] | None = None


scheduled_message_mode = sa.Enum(
    "at_time",
    "when_online",
    name="scheduledmessagemode",
)
scheduled_message_mode_reuse = sa.Enum(
    "at_time",
    "when_online",
    name="scheduledmessagemode",
    create_type=False,
)
scheduled_message_status = sa.Enum(
    "pending",
    "dispatched",
    "canceled",
    "failed",
    name="scheduledmessagestatus",
)
scheduled_message_status_reuse = sa.Enum(
    "pending",
    "dispatched",
    "canceled",
    "failed",
    name="scheduledmessagestatus",
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
    scheduled_message_mode.create(bind, checkfirst=True)
    scheduled_message_status.create(bind, checkfirst=True)

    tables = _table_names(bind)

    if "scheduled_messages" not in tables:
        op.create_table(
            "scheduled_messages",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("chat_id", sa.Integer(), sa.ForeignKey("chats.id", ondelete="CASCADE"), nullable=False),
            sa.Column("sender_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
            sa.Column("target_user_id", sa.Integer(), sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
            sa.Column("content", sa.Text(), nullable=False, server_default=""),
            sa.Column("mode", scheduled_message_mode_reuse, nullable=False, server_default="at_time"),
            sa.Column("status", scheduled_message_status_reuse, nullable=False, server_default="pending"),
            sa.Column("send_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("reply_to_message_id", sa.Integer(), sa.ForeignKey("messages.id", ondelete="SET NULL"), nullable=True),
            sa.Column(
                "dispatched_message_id",
                sa.Integer(),
                sa.ForeignKey("messages.id", ondelete="SET NULL"),
                nullable=True,
            ),
            sa.Column("error_message", sa.String(length=300), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("dispatched_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("canceled_at", sa.DateTime(timezone=True), nullable=True),
        )

    if "scheduled_messages" in _table_names(bind):
        scheduled_indexes = _index_names(bind, "scheduled_messages")
        if "ix_scheduled_messages_chat_id" not in scheduled_indexes:
            op.create_index("ix_scheduled_messages_chat_id", "scheduled_messages", ["chat_id"], unique=False)
        if "ix_scheduled_messages_sender_id" not in scheduled_indexes:
            op.create_index("ix_scheduled_messages_sender_id", "scheduled_messages", ["sender_id"], unique=False)
        if "ix_scheduled_messages_target_user_id" not in scheduled_indexes:
            op.create_index("ix_scheduled_messages_target_user_id", "scheduled_messages", ["target_user_id"], unique=False)
        if "ix_scheduled_messages_mode" not in scheduled_indexes:
            op.create_index("ix_scheduled_messages_mode", "scheduled_messages", ["mode"], unique=False)
        if "ix_scheduled_messages_status" not in scheduled_indexes:
            op.create_index("ix_scheduled_messages_status", "scheduled_messages", ["status"], unique=False)
        if "ix_scheduled_messages_send_at" not in scheduled_indexes:
            op.create_index("ix_scheduled_messages_send_at", "scheduled_messages", ["send_at"], unique=False)
        if "ix_scheduled_messages_dispatched_message_id" not in scheduled_indexes:
            op.create_index(
                "ix_scheduled_messages_dispatched_message_id",
                "scheduled_messages",
                ["dispatched_message_id"],
                unique=False,
            )
        scheduled_columns = _column_names(bind, "scheduled_messages")
        if {"content", "mode", "status"}.issubset(scheduled_columns):
            with op.batch_alter_table("scheduled_messages") as batch_op:
                batch_op.alter_column("content", server_default=None)
                batch_op.alter_column("mode", server_default=None)
                batch_op.alter_column("status", server_default=None)

    if "scheduled_message_attachments" not in tables:
        op.create_table(
            "scheduled_message_attachments",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column(
                "scheduled_message_id",
                sa.Integer(),
                sa.ForeignKey("scheduled_messages.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column("media_file_id", sa.Integer(), sa.ForeignKey("media_files.id", ondelete="CASCADE"), nullable=False),
            sa.Column("sort_order", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.UniqueConstraint(
                "scheduled_message_id",
                "media_file_id",
                name="uq_scheduled_message_attachment_media",
            ),
        )

    if "scheduled_message_attachments" in _table_names(bind):
        attachment_indexes = _index_names(bind, "scheduled_message_attachments")
        if "ix_scheduled_message_attachments_scheduled_message_id" not in attachment_indexes:
            op.create_index(
                "ix_scheduled_message_attachments_scheduled_message_id",
                "scheduled_message_attachments",
                ["scheduled_message_id"],
                unique=False,
            )
        if "ix_scheduled_message_attachments_media_file_id" not in attachment_indexes:
            op.create_index(
                "ix_scheduled_message_attachments_media_file_id",
                "scheduled_message_attachments",
                ["media_file_id"],
                unique=False,
            )
        attachment_columns = _column_names(bind, "scheduled_message_attachments")
        if "sort_order" in attachment_columns:
            with op.batch_alter_table("scheduled_message_attachments") as batch_op:
                batch_op.alter_column("sort_order", server_default=None)


def downgrade() -> None:
    bind = op.get_bind()

    if "scheduled_message_attachments" in _table_names(bind):
        attachment_indexes = _index_names(bind, "scheduled_message_attachments")
        if "ix_scheduled_message_attachments_media_file_id" in attachment_indexes:
            op.drop_index(
                "ix_scheduled_message_attachments_media_file_id",
                table_name="scheduled_message_attachments",
            )
        if "ix_scheduled_message_attachments_scheduled_message_id" in attachment_indexes:
            op.drop_index(
                "ix_scheduled_message_attachments_scheduled_message_id",
                table_name="scheduled_message_attachments",
            )
        op.drop_table("scheduled_message_attachments")

    if "scheduled_messages" in _table_names(bind):
        scheduled_indexes = _index_names(bind, "scheduled_messages")
        if "ix_scheduled_messages_dispatched_message_id" in scheduled_indexes:
            op.drop_index("ix_scheduled_messages_dispatched_message_id", table_name="scheduled_messages")
        if "ix_scheduled_messages_send_at" in scheduled_indexes:
            op.drop_index("ix_scheduled_messages_send_at", table_name="scheduled_messages")
        if "ix_scheduled_messages_status" in scheduled_indexes:
            op.drop_index("ix_scheduled_messages_status", table_name="scheduled_messages")
        if "ix_scheduled_messages_mode" in scheduled_indexes:
            op.drop_index("ix_scheduled_messages_mode", table_name="scheduled_messages")
        if "ix_scheduled_messages_target_user_id" in scheduled_indexes:
            op.drop_index("ix_scheduled_messages_target_user_id", table_name="scheduled_messages")
        if "ix_scheduled_messages_sender_id" in scheduled_indexes:
            op.drop_index("ix_scheduled_messages_sender_id", table_name="scheduled_messages")
        if "ix_scheduled_messages_chat_id" in scheduled_indexes:
            op.drop_index("ix_scheduled_messages_chat_id", table_name="scheduled_messages")
        op.drop_table("scheduled_messages")

    scheduled_message_status.drop(bind, checkfirst=True)
    scheduled_message_mode.drop(bind, checkfirst=True)
