from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.models.user import User
from app.schemas.customization import CustomizationOut, CustomizationUpdate
from app.services.customization_service import get_or_create_settings, update_settings

router = APIRouter(prefix="/customization", tags=["Customization"])


@router.get("/me", response_model=CustomizationOut)
def get_my_settings(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> CustomizationOut:
    settings = get_or_create_settings(db, user_id=current_user.id)
    return CustomizationOut.model_validate(settings)


@router.put("/me", response_model=CustomizationOut)
def update_my_settings(
    payload: CustomizationUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> CustomizationOut:
    settings = update_settings(db, user_id=current_user.id, payload=payload)
    return CustomizationOut.model_validate(settings)
