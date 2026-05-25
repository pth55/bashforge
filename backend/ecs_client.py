"""
ecs_client.py  —  ECS Fargate client for BashForge sandbox containers.

Mock mode  (MOCK_ECS=true): returns the local Docker sandbox hostname, no AWS calls.
Real mode              : boto3 run_task per session, polls until RUNNING, returns private IP.
"""
import asyncio
import logging
import os
import time
from typing import Optional

from config import get_settings

log = logging.getLogger(__name__)

SANDBOX_PORT = 8765


class MockECSClient:
    async def run_task(self, session_id: str, ws_token: str) -> tuple[str, str]:
        log.info("[MOCK ECS] Would launch Fargate task for session %s", session_id)
        await asyncio.sleep(0.5)
        host = os.environ.get("MOCK_SANDBOX_HOST", "sandbox")
        return host, ""

    async def stop_task(self, task_arn: str) -> None:
        log.info("[MOCK ECS] Would stop task %s", task_arn or "<none>")


class RealECSClient:
    def __init__(self) -> None:
        self.settings = get_settings()
        import boto3
        self._ecs = boto3.client("ecs", region_name=self.settings.aws_region)

    async def run_task(self, session_id: str, ws_token: str) -> tuple[str, str]:
        s = self.settings
        response = await asyncio.to_thread(
            self._ecs.run_task,
            cluster=s.ecs_cluster,
            taskDefinition=s.ecs_task_definition,
            launchType="FARGATE",
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets": s.ecs_subnets,
                    "securityGroups": s.ecs_security_groups,
                    "assignPublicIp": "ENABLED" if s.assign_public_ip else "DISABLED",
                }
            },
            overrides={
                "containerOverrides": [{
                    "name": "bash-session",
                    "environment": [
                        {"name": "WS_TOKEN",    "value": ws_token},
                        {"name": "SESSION_ID",  "value": session_id},
                    ],
                }]
            },
            tags=[{"key": "BashForge-Session", "value": session_id}],
        )
        failures = response.get("failures", [])
        if failures:
            raise RuntimeError(f"ECS run_task failures: {failures}")

        task_arn = response["tasks"][0]["taskArn"]
        log.info("ECS task launched: %s for session %s", task_arn, session_id)

        await self._wait_running(task_arn)
        ip = await self._get_task_ip(task_arn)
        log.info("ECS task RUNNING: %s  ip=%s", task_arn, ip)
        return ip, task_arn

    async def _wait_running(self, task_arn: str, timeout: int = 120) -> None:
        deadline = time.time() + timeout
        while time.time() < deadline:
            resp = await asyncio.to_thread(
                self._ecs.describe_tasks,
                cluster=self.settings.ecs_cluster,
                tasks=[task_arn],
            )
            if not resp.get("tasks"):
                raise RuntimeError(f"ECS task {task_arn} not found")

            task   = resp["tasks"][0]
            status = task["lastStatus"]

            if status == "RUNNING":
                return
            if status in ("STOPPED", "DEPROVISIONING"):
                reason = task.get("stoppedReason", "unknown")
                raise RuntimeError(f"ECS task stopped unexpectedly: {reason}")

            await asyncio.sleep(2)

        raise TimeoutError(f"ECS task {task_arn} did not reach RUNNING within {timeout}s")

    async def _get_task_ip(self, task_arn: str) -> str:
        s = self.settings
        ip_key = "privateIPv4Address"  # backend proxies via private IP (same VPC); public IP for ECR pull only
        deadline = time.time() + 30
        while time.time() < deadline:
            resp = await asyncio.to_thread(
                self._ecs.describe_tasks,
                cluster=s.ecs_cluster,
                tasks=[task_arn],
            )
            for attachment in resp["tasks"][0].get("attachments", []):
                if attachment["type"] == "ElasticNetworkInterface":
                    for detail in attachment.get("details", []):
                        if detail["name"] == ip_key and detail.get("value"):
                            return detail["value"]
            await asyncio.sleep(2)
        raise RuntimeError(f"Could not find {ip_key} for ECS task {task_arn} within 30s")

    async def stop_task(self, task_arn: str) -> None:
        if not task_arn:
            return
        try:
            await asyncio.to_thread(
                self._ecs.stop_task,
                cluster=self.settings.ecs_cluster,
                task=task_arn,
                reason="Session expired or terminated",
            )
            log.info("Stopped ECS task %s", task_arn)
        except Exception as e:
            log.warning("Failed to stop ECS task %s: %s", task_arn, e)


def get_ecs_client() -> MockECSClient | RealECSClient:
    s = get_settings()
    if s.mock_ecs:
        return MockECSClient()
    return RealECSClient()
