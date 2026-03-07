from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.customization import UserCustomization
from app.schemas.customization import CustomizationUpdate


def get_or_create_settings(db: Session, user_id: int) -> UserCustomization:
    settings = db.scalar(select(UserCustomization).where(UserCustomization.user_id == user_id))
    if settings:
        return settings

    settings = UserCustomization(user_id=user_id)
    db.add(settings)
    db.commit()
    db.refresh(settings)
    return settings


def update_settings(db: Session, user_id: int, payload: CustomizationUpdate) -> UserCustomization:
    settings = get_or_create_settings(db, user_id=user_id)

    if payload.theme is not None:
        settings.theme = payload.theme
    if payload.accent_color is not None:
        settings.accent_color = payload.accent_color
    if payload.layout_json is not None:
        settings.layout_json = payload.layout_json
    if payload.notifications_json is not None:
        settings.notifications_json = payload.notifications_json
    if payload.privacy_json is not None:
        settings.privacy_json = payload.privacy_json

    db.add(settings)
    db.commit()
    db.refresh(settings)
    return settings
