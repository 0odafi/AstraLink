from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.api.deps import get_db
from app.schemas.auth import (
    LoginRequest,
    PhoneCodeRequest,
    PhoneCodeResponse,
    PhoneCodeVerifyRequest,
    RefreshRequest,
    RegisterRequest,
    TokenResponse,
)
from app.services.auth_service import (
    authenticate_user,
    build_token_response,
    request_phone_login_code,
    register_user,
    revoke_refresh_token,
    rotate_refresh_token,
    verify_phone_login_code,
)

router = APIRouter(prefix="/auth", tags=["Auth"])


@router.post("/request-code", response_model=PhoneCodeResponse)
def request_code(payload: PhoneCodeRequest, db: Session = Depends(get_db)) -> PhoneCodeResponse:
    try:
        return request_phone_login_code(db, payload.phone)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc


@router.post("/verify-code", response_model=TokenResponse)
def verify_code(payload: PhoneCodeVerifyRequest, db: Session = Depends(get_db)) -> TokenResponse:
    try:
        user = verify_phone_login_code(db, payload)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return build_token_response(db, user)


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
def register(payload: RegisterRequest, db: Session = Depends(get_db)) -> TokenResponse:
    try:
        user = register_user(db, payload)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    return build_token_response(db, user)


@router.post("/login", response_model=TokenResponse)
def login(payload: LoginRequest, db: Session = Depends(get_db)) -> TokenResponse:
    user = authenticate_user(db, login=payload.login, password=payload.password)
    if not user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid login or password")
    return build_token_response(db, user)


@router.post("/refresh", response_model=TokenResponse)
def refresh(payload: RefreshRequest, db: Session = Depends(get_db)) -> TokenResponse:
    try:
        return rotate_refresh_token(db, payload.refresh_token)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=str(exc)) from exc


@router.post("/logout")
def logout(payload: RefreshRequest, db: Session = Depends(get_db)) -> dict[str, bool]:
    revoked = revoke_refresh_token(db, payload.refresh_token)
    return {"revoked": revoked}
