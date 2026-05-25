"""
main.py  —  FastAPI backend for BashForge
"""
import asyncio
import logging
import time
import uuid
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

from config import get_settings
from redis_client import close_redis, session_list_all, session_ttl as get_ttl
from session_manager import (
    create_session,
    get_session,
    get_session_remaining,
    session_reaper,
    terminate_session,
)
from ws_proxy import WSProxy

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s — %(message)s",
)
log      = logging.getLogger(__name__)
settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("BashForge backend starting (mock_ecs=%s)", settings.mock_ecs)
    reaper_task = asyncio.create_task(session_reaper())
    yield
    reaper_task.cancel()
    try:
        await reaper_task
    except asyncio.CancelledError:
        pass
    await close_redis()
    log.info("BashForge backend shut down")


app = FastAPI(title="BashForge API", version="2.0.0", lifespan=lifespan, docs_url="/api/docs")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _cookie_val(request: Request) -> Optional[str]:
    return request.cookies.get(settings.session_cookie_name)


def _set_session_cookie(response: Response, session_id: str) -> None:
    response.set_cookie(
        key=settings.session_cookie_name,
        value=session_id,
        httponly=True,
        secure=settings.secure_cookies,
        samesite="strict",
        max_age=settings.session_ttl_seconds,
        path="/",
    )


def _clear_session_cookie(response: Response) -> None:
    response.delete_cookie(key=settings.session_cookie_name, path="/")


# ── Health ────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    return {"status": "ok", "time": time.time()}


# ── Sessions ──────────────────────────────────────────────────────

@app.post("/api/sessions/create")
async def api_create_session(request: Request, response: Response):
    # Resume if a valid session cookie already exists
    existing_id = _cookie_val(request)
    if existing_id:
        session_data = await get_session(existing_id)
        if session_data:
            remaining = await get_session_remaining(existing_id)
            if remaining > 0:
                log.info("Resuming session %s (%ds remaining)", existing_id, remaining)
                _set_session_cookie(response, existing_id)
                return {"status": "resumed", "session_id": existing_id, "ttl": remaining}
        await terminate_session(existing_id)

    # Enforce global session cap
    active = await session_list_all()
    if len(active) >= settings.max_concurrent_sessions:
        ttls    = [t for sid in active if (t := await get_ttl(sid)) > 0]
        min_wait = min(ttls) if ttls else 60
        raise HTTPException(
            status_code=503,
            detail=f"CAPACITY_REACHED:{len(active)}:{settings.max_concurrent_sessions}:{min_wait}",
        )

    session_id = str(uuid.uuid4())
    try:
        await create_session(session_id)
    except RuntimeError as e:
        raise HTTPException(status_code=500, detail=str(e))

    remaining = await get_session_remaining(session_id)
    _set_session_cookie(response, session_id)
    log.info("Created session %s", session_id)
    return {"status": "created", "session_id": session_id, "ttl": remaining}


@app.get("/api/sessions/status")
async def api_session_status(request: Request):
    session_id = _cookie_val(request)
    if not session_id:
        raise HTTPException(status_code=404, detail="No session")
    remaining = await get_session_remaining(session_id)
    if remaining <= 0:
        raise HTTPException(status_code=404, detail="Session not found or expired")
    return {"session_id": session_id, "remaining": remaining}


@app.delete("/api/sessions/terminate")
async def api_terminate_session(request: Request, response: Response):
    session_id = _cookie_val(request)
    if not session_id:
        return {"status": "no_session"}
    await terminate_session(session_id)
    _clear_session_cookie(response)
    log.info("User terminated session %s", session_id)
    return {"status": "terminated"}


@app.get("/api/sessions/count")
async def api_session_count():
    active = await session_list_all()
    return {"count": len(active)}


# ── WebSocket ─────────────────────────────────────────────────────

@app.websocket("/ws/{session_id}")
async def ws_endpoint(websocket: WebSocket, session_id: str):
    cookie_val = websocket.cookies.get(settings.session_cookie_name)
    if cookie_val != session_id:
        await websocket.close(code=4001, reason="Session mismatch")
        return

    session_data = await get_session(session_id)
    if not session_data:
        await websocket.close(code=4004, reason="Session not found or expired")
        return

    await websocket.accept()
    log.info("WebSocket accepted for session %s", session_id)

    proxy = WSProxy(
        browser_ws=websocket,
        pod_ip=session_data["pod_ip"],
        session_id=session_id,
        ws_token=session_data["ws_token"],
    )
    try:
        await proxy.run()
    except WebSocketDisconnect:
        pass
    except Exception as e:
        log.error("WebSocket proxy error for session %s: %s", session_id, e)
    finally:
        log.info("WebSocket closed for session %s", session_id)
