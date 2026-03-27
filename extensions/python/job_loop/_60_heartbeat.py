from typing import Any
from helpers.extension import Extension
from helpers.heartbeat import HeartbeatManager


class HeartbeatTick(Extension):
    async def execute(self, data: dict[str, Any] | None = None, **kwargs):
        await HeartbeatManager.get().tick()
