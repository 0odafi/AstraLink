from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app.api.routers import auth, chats, realtime, releases, users
from app.core.config import get_settings
from app.core.migrations import run_migrations
from app.realtime.fanout import realtime_fanout

settings = get_settings()


@asynccontextmanager
async def lifespan(_: FastAPI):
    if settings.database_auto_migrate:
        run_migrations()
    await realtime_fanout.startup()
    try:
        yield
    finally:
        await realtime_fanout.shutdown()


app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    description="A messenger API with phone auth, chats and realtime events.",
    lifespan=lifespan,
)

if settings.cors_origin_list == ["*"]:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


app.include_router(auth.router, prefix="/api")
app.include_router(users.router, prefix="/api")
app.include_router(chats.router, prefix="/api")
app.include_router(releases.router, prefix="/api")
app.include_router(realtime.router, prefix="/api/realtime")

media_dir = Path(settings.media_root).resolve()
media_dir.mkdir(parents=True, exist_ok=True)
media_path = settings.media_url_path if settings.media_url_path.startswith("/") else f"/{settings.media_url_path}"
app.mount(media_path, StaticFiles(directory=media_dir), name="media")

frontend_dir = Path(__file__).resolve().parent.parent / "web"
if frontend_dir.exists():
    app.mount("/web", StaticFiles(directory=frontend_dir), name="web")


@app.get("/", include_in_schema=False)
def web_index():
    if frontend_dir.exists():
        return FileResponse(frontend_dir / "index.html")
    return {"message": "AstraLink API is running. Open /docs for API schema."}
