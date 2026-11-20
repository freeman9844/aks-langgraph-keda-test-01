import asyncio
import logging
from typing import TypedDict

from fastapi import FastAPI, HTTPException, Response
from langgraph.graph import END, START, StateGraph
from prometheus_client import CONTENT_TYPE_LATEST, Gauge, generate_latest


class State(TypedDict):
    gate: asyncio.Event


async def wait_for_release(state: State):
    await state["gate"].wait()
    return {}


builder = StateGraph(State)
builder.add_node("wait", wait_for_release)
builder.add_edge(START, "wait")
builder.add_edge("wait", END)
graph = builder.compile()
ACTIVE = Gauge("agent_runs_active", "Active top-level graph executions")
app = FastAPI()
runs: dict[str, tuple[asyncio.Event, asyncio.Task]] = {}


async def run_graph(gate: asyncio.Event, timeout: float = 900):
    with ACTIVE.track_inprogress():
        async with asyncio.timeout(timeout):
            await graph.ainvoke({"gate": gate})


async def execute(run_id: str, gate: asyncio.Event):
    try:
        await run_graph(gate)
    except TimeoutError:
        logging.warning("Run expired: %s", run_id)
    finally:
        runs.pop(run_id, None)


@app.post("/runs/{run_id}", status_code=202)
async def start(run_id: str):
    if run_id in runs:
        raise HTTPException(409, "Run already active")
    gate = asyncio.Event()
    runs[run_id] = (gate, asyncio.create_task(execute(run_id, gate)))
    return {"id": run_id}


@app.delete("/runs/{run_id}", status_code=204)
async def release(run_id: str):
    if run_id not in runs:
        raise HTTPException(404, "Run not active on this pod")
    gate, task = runs[run_id]
    gate.set()
    await task
    return Response(status_code=204)


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), headers={"Content-Type": CONTENT_TYPE_LATEST})


@app.get("/ready")
async def ready():
    return {"ready": True}
