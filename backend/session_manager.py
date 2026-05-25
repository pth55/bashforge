"""
session_manager.py  —  session lifecycle: create → ECS task, terminate → stop task, reaper.
"""
import asyncio
import logging
import secrets
import time
from typing import Optional

from config import get_settings
from ecs_client import get_ecs_client
from redis_client import (
    session_delete, session_get, session_list_all,
    session_set, session_ttl,
)

log = logging.getLogger(__name__)


async def create_session(session_id: str) -> dict:
    settings  = get_settings()
    ecs       = get_ecs_client()
    ws_token  = settings.mock_ws_token if settings.mock_ecs else secrets.token_hex(32)

    try:
        pod_ip, task_arn = await ecs.run_task(session_id, ws_token)
    except Exception as e:
        log.error("Failed to start ECS task for session %s: %s", session_id, e)
        raise RuntimeError(f"Failed to start container: {e}") from e

    now  = time.time()
    data = {
        "session_id": session_id,
        "task_arn":   task_arn,
        "pod_ip":     pod_ip,
        "ws_token":   ws_token,
        "created_at": now,
        "expires_at": now + settings.session_ttl_seconds,
    }
    await session_set(session_id, data, settings.session_ttl_seconds)
    log.info("Session created: %s  task_arn=%s  ip=%s", session_id, task_arn or "mock", pod_ip)
    return data


async def terminate_session(session_id: str) -> None:
    data = await session_get(session_id)
    if not data:
        log.debug("terminate_session: %s not found in Redis", session_id)
        return
    ecs = get_ecs_client()
    await ecs.stop_task(data.get("task_arn", ""))
    await session_delete(session_id)
    log.info("Session terminated: %s", session_id)


async def get_session(session_id: str) -> Optional[dict]:
    return await session_get(session_id)


async def get_session_remaining(session_id: str) -> int:
    return await session_ttl(session_id)


async def session_reaper() -> None:
    log.info("Session reaper started")
    while True:
        try:
            await asyncio.sleep(60)
            ids = await session_list_all()
            for sid in ids:
                ttl_val = await session_ttl(sid)
                if ttl_val == -2:
                    data = await session_get(sid)
                    if data:
                        ecs = get_ecs_client()
                        await ecs.stop_task(data.get("task_arn", ""))
                    await session_delete(sid)
                    log.info("Reaper cleaned up expired session %s", sid)
        except asyncio.CancelledError:
            log.info("Session reaper stopping")
            break
        except Exception as e:
            log.error("Reaper error: %s", e)
