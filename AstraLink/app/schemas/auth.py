from pydantic import BaseModel, Field

from app.schemas.user import UserPublic


class PhoneCodeRequest(BaseModel):
    phone: str = Field(min_length=10, max_length=24)


class PhoneCodeResponse(BaseModel):
    phone: str
    code_token: str
    expires_in_seconds: int
    is_registered: bool


class PhoneCodeVerifyRequest(BaseModel):
    phone: str = Field(min_length=10, max_length=24)
    code_token: str = Field(min_length=20, max_length=512)
    code: str = Field(min_length=4, max_length=8)
    first_name: str | None = Field(default=None, max_length=80)
    last_name: str | None = Field(default=None, max_length=80)


class RegisterRequest(BaseModel):
    username: str = Field(min_length=3, max_length=40)
    email: str = Field(min_length=5, max_length=120)
    password: str = Field(min_length=8, max_length=128)


class LoginRequest(BaseModel):
    login: str = Field(min_length=3, max_length=120, description="Username or email")
    password: str = Field(min_length=8, max_length=128)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=20, max_length=512)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    needs_profile_setup: bool = False
    user: UserPublic
