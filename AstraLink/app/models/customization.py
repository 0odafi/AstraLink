from datetime import UTC, datetime
from typing import TYPE_CHECKING

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.core.database import Base

if TYPE_CHECKING:
    from app.models.user import User


class UserCustomization(Base):
    __tablename__ = "user_customizations"

    id: Mapped[int] = mapped_column(primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), unique=True, index=True)
    theme: Mapped[str] = mapped_column(String(40), default="dark")
    accent_color: Mapped[str] = mapped_column(String(20), default="#00D1FF")
    layout_json: Mapped[str] = mapped_column(Text, default='{"density":"comfortable","chatList":"left"}')
    notifications_json: Mapped[str] = mapped_column(
        Text,
        default='{"push":true,"email":false,"mentionsOnly":false}',
    )
    privacy_json: Mapped[str] = mapped_column(Text, default='{"lastSeen":"contacts","phone":"nobody"}')
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        default=lambda: datetime.now(UTC),
        onupdate=lambda: datetime.now(UTC),
    )

    user: Mapped["User"] = relationship(back_populates="custom_settings")
