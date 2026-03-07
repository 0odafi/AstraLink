import json
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query, status

from app.core.config import get_settings

router = APIRouter(prefix="/releases", tags=["Releases"])

SUPPORTED_PLATFORMS = {"windows", "android", "web"}


def _load_manifest() -> dict:
    settings = get_settings()
    path = Path(settings.release_manifest_path)
    if not path.exists():
        return {"channels": {}}
    return json.loads(path.read_text(encoding="utf-8"))


@router.get("/latest/{platform}")
def latest_release(
    platform: str,
    channel: str = Query(default="stable", min_length=1, max_length=30),
) -> dict:
    platform = platform.lower()
    if platform not in SUPPORTED_PLATFORMS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unsupported platform '{platform}'",
        )

    manifest = _load_manifest()
    platform_release = (
        manifest.get("channels", {})
        .get(channel, {})
        .get(platform)
    )
    if not platform_release:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Release for platform '{platform}' and channel '{channel}' not found",
        )

    return {
        "platform": platform,
        "channel": channel,
        "generated_at": manifest.get("generated_at"),
        **platform_release,
    }
