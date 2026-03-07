from datetime import datetime

from pydantic import BaseModel, Field


class CustomizationOut(BaseModel):
    user_id: int
    theme: str
    accent_color: str
    layout_json: str
    notifications_json: str
    privacy_json: str
    updated_at: datetime

    model_config = {"from_attributes": True}


class CustomizationUpdate(BaseModel):
    theme: str | None = Field(default=None, max_length=40)
    accent_color: str | None = Field(default=None, max_length=20)
    layout_json: str | None = None
    notifications_json: str | None = None
    privacy_json: str | None = None
