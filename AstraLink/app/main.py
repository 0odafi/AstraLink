from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app.api.routers import auth, chats, customization, realtime, releases, social, users
from app.core.config import get_settings
from app.core.database import create_tables

settings = get_settings()


@asynccontextmanager
async def lifespan(_: FastAPI):
    create_tables()
    yield


app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    description="A messenger-social network API with realtime chat and customization.",
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
app.include_router(social.router, prefix="/api")
app.include_router(customization.router, prefix="/api")
app.include_router(releases.router, prefix="/api")
app.include_router(realtime.router, prefix="/api/realtime")

frontend_dir = Path(__file__).resolve().parent.parent / "web"
if frontend_dir.exists():
    app.mount("/web", StaticFiles(directory=frontend_dir), name="web")


@app.get("/", include_in_schema=False)
def web_index():
    if frontend_dir.exists():
        return FileResponse(frontend_dir / "index.html")
    return {"message": "AstraLink API is running. Open /docs for API schema."}
