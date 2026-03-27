import asyncio
import threading
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from helpers.print_style import PrintStyle
from helpers.defer import DeferredTask
from helpers import projects


class _ProjectHeartbeatState:
    __slots__ = ("last_run", "running", "context_id", "_deferred_task")

    def __init__(self, context_id: str):
        self.last_run: Optional[datetime] = None
        self.running: bool = False
        self.context_id: str = context_id
        self._deferred_task: Optional[DeferredTask] = None


class HeartbeatManager:
    _instance: Optional["HeartbeatManager"] = None
    _lock = threading.RLock()

    @classmethod
    def get(cls) -> "HeartbeatManager":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def __init__(self):
        self._states: Dict[str, _ProjectHeartbeatState] = {}
        self._printer = PrintStyle(italic=True, font_color="cyan", padding=False)

    def _get_state(self, project_name: str) -> _ProjectHeartbeatState:
        if project_name not in self._states:
            context_id = f"heartbeat-{project_name}"
            self._states[project_name] = _ProjectHeartbeatState(context_id)
        return self._states[project_name]

    async def tick(self):
        try:
            project_list = projects.get_active_projects_list()
        except Exception as e:
            PrintStyle.error(f"Heartbeat: failed to list projects: {e}")
            return

        for proj in project_list:
            name = proj.get("name", "")
            if not name:
                continue
            try:
                await self._check_project(name)
            except Exception as e:
                PrintStyle.error(f"Heartbeat: error checking project '{name}': {e}")

    async def _check_project(self, project_name: str):
        try:
            basic_data = projects.load_basic_project_data(project_name)
        except Exception:
            return

        hb: dict = basic_data.get("heartbeat", {})  # type: ignore
        if not hb.get("enabled", False):
            return

        prompt = (hb.get("prompt") or "").strip()
        if not prompt:
            return

        interval = max(int(hb.get("interval_seconds", 300)), 30)
        state = self._get_state(project_name)

        # Skip if already running
        if state.running:
            self._printer.print(f"Heartbeat: '{project_name}' still running, skipping")
            return

        # Check interval elapsed
        now = datetime.now(timezone.utc)
        if state.last_run is not None:
            elapsed = (now - state.last_run).total_seconds()
            if elapsed < interval:
                return

        # Launch heartbeat
        self._printer.print(f"Heartbeat: launching for project '{project_name}'")
        state.running = True
        state.last_run = now
        await self._run_heartbeat(project_name, prompt, state)

    async def _run_heartbeat(self, project_name: str, prompt: str, state: _ProjectHeartbeatState):
        from agent import Agent, AgentContext, UserMessage
        from initialize import initialize_agent
        from helpers.persist_chat import save_tmp_chat

        async def _heartbeat_wrapper():
            agent = None
            try:
                # Get or create context
                context = AgentContext.get(state.context_id)
                if context is None:
                    config = initialize_agent()
                    # Derive a display title
                    try:
                        basic = projects.load_basic_project_data(project_name)
                        title = basic.get("title") or project_name
                    except Exception:
                        title = project_name
                    context = AgentContext(
                        config,
                        id=state.context_id,
                        name=f"Heartbeat: {title}",
                    )
                    projects.activate_project(context.id, project_name)
                    save_tmp_chat(context)

                AgentContext.use(context.id)
                agent = context.streaming_agent or context.agent0

                # Log user message
                msg_id = str(uuid.uuid4())
                task_prompt = f"## Heartbeat\n{prompt}"
                context.log.log(
                    type="user",
                    heading="",
                    content=task_prompt,
                    id=msg_id,
                )
                agent.hist_add_user_message(
                    UserMessage(
                        message=task_prompt,
                        system_message=[],
                        attachments=[],
                        id=msg_id,
                    )
                )
                save_tmp_chat(context)

                result = await agent.monologue()
                PrintStyle.success(f"Heartbeat: '{project_name}' completed: {result}")
                save_tmp_chat(context)
            except asyncio.CancelledError:
                PrintStyle.warning(f"Heartbeat: '{project_name}' cancelled")
                raise
            except Exception as e:
                PrintStyle.error(f"Heartbeat: '{project_name}' failed: {e}")
            finally:
                state.running = False

        deferred = DeferredTask(thread_name="HeartbeatManager")
        state._deferred_task = deferred
        deferred.start_task(_heartbeat_wrapper)
        # Yield briefly so the thread can spin up
        await asyncio.sleep(0.1)
