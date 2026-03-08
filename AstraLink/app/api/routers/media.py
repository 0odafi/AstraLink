import mimetypes
from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile, status
from sqlalchemy.orm import Session

from app.api.deps import get_current_user, get_db
from app.core.config import get_settings
from app.models.chat import MediaFile
from app.models.user import User
from app.schemas.chat import MediaUploadOut
from app.services.chat_service import get_chat_for_member

router = APIRouter(prefix="/media", tags=["Media"])


def _safe_original_name(raw_name: str | None) -> str:
    name = (raw_name or "").strip()
    if not name:
        return "file.bin"
    cleaned = Path(name).name
    return cleaned[:255] if cleaned else "file.bin"


@router.post("/upload", response_model=MediaUploadOut, status_code=status.HTTP_201_CREATED)
async def upload_media(
    chat_id: int = Query(..., ge=1),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MediaUploadOut:
    try:
        _ = get_chat_for_member(db, chat_id=chat_id, user_id=current_user.id)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(exc)) from exc

    settings = get_settings()
    payload = await file.read()
    if not payload:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Uploaded file is empty")
    if len(payload) > settings.max_upload_bytes:
        raise HTTPException(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            detail=f"File is too large (max {settings.max_upload_bytes} bytes)",
        )

    original_name = _safe_original_name(file.filename)
    suffix = Path(original_name).suffix.lower()
    storage_name = f"{uuid4().hex}{suffix}" if suffix else uuid4().hex
    mime_type = (file.content_type or "").strip() or mimetypes.guess_type(original_name)[0] or "application/octet-stream"

    media_root = Path(settings.media_root).resolve()
    media_root.mkdir(parents=True, exist_ok=True)
    target = media_root / storage_name
    target.write_bytes(payload)

    media = MediaFile(
        uploader_id=current_user.id,
        chat_id=chat_id,
        storage_name=storage_name,
        original_name=original_name,
        mime_type=mime_type,
        size_bytes=len(payload),
        is_committed=False,
    )
    db.add(media)
    db.commit()
    db.refresh(media)

    base = settings.media_url_path.rstrip("/")
    if not base:
        base = "/media"
    if not base.startswith("/"):
        base = f"/{base}"

    return MediaUploadOut(
        id=media.id,
        file_name=media.original_name,
        mime_type=media.mime_type,
        size_bytes=media.size_bytes,
        url=f"{base}/{media.storage_name}",
        is_image=media.mime_type.startswith("image/"),
    )
