import asyncio
from contextlib import aclosing
import json
import os
from pathlib import Path
from typing import Literal, TypedDict

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.responses import StreamingResponse
from langgraph.config import get_stream_writer
from langgraph.graph import END, START, StateGraph
from prometheus_client import CONTENT_TYPE_LATEST, Gauge, generate_latest


class State(TypedDict):
    gate: asyncio.Event
    backend: str
    pace: float


async def respond(state: State):
    emit = get_stream_writer()
    if state["backend"] == "probe":
        emit("ready")
        await state["gate"].wait()
    else:
        from azure.identity.aio import WorkloadIdentityCredential
        from openai import AsyncOpenAI

        async with WorkloadIdentityCredential() as credential:
            token = await credential.get_token("https://cognitiveservices.azure.com/.default")
            async with AsyncOpenAI(api_key=token.token, base_url=os.environ["MODEL_ENDPOINT"] + "/openai/v1/") as client:
                stream = await client.chat.completions.create(
                    model="stream-lab", stream=True, max_completion_tokens=160,
                    messages=[{"role": "user", "content": "Write the numbers one to forty in English, separated by commas."}],
                )
                async with stream:
                    async for chunk in stream:
                        if chunk.choices and (text := chunk.choices[0].delta.content):
                            emit(text)
                            await asyncio.sleep(state["pace"])
    return {}


builder = StateGraph(State)
builder.add_node("respond", respond)
builder.add_edge(START, "respond")
builder.add_edge("respond", END)
graph = builder.compile()
ACTIVE = Gauge("agent_runs_active", "Active LangGraph SSE streams")
app = FastAPI()
runs: dict[str, asyncio.Event] = {}
DRAIN = Path("/tmp/runlab-draining")


async def stream_run(graph, inputs, config=None):
    with ACTIVE.track_inprogress():
        async with aclosing(graph.astream(inputs, config=config, stream_mode="custom")) as events:
            async for event in events:
                yield f"event: delta\ndata: {json.dumps(event)}\n\n"
        yield "event: done\ndata: {}\n\n"


@app.get("/streams/{run_id}")
async def start(run_id: str, backend: Literal["probe", "foundry"] = "probe", pace: float = Query(0, ge=0, le=1)):
    if DRAIN.exists():
        raise HTTPException(503, "Draining")
    if run_id in runs:
        raise HTTPException(409, "Stream already active")
    if backend == "foundry" and not os.getenv("MODEL_ENDPOINT"):
        raise HTTPException(503, "Model not configured")
    gate = runs[run_id] = asyncio.Event()

    async def body():
        try:
            async with asyncio.timeout(900), aclosing(stream_run(graph, {"gate": gate, "backend": backend, "pace": pace})) as events:
                async for event in events:
                    yield event
        finally:
            runs.pop(run_id, None)

    return StreamingResponse(body(), media_type="text/event-stream", headers={"Cache-Control": "no-cache"})


@app.delete("/runs/{run_id}", status_code=204)
async def release(run_id: str):
    if run_id not in runs:
        raise HTTPException(404, "Run not active on this pod")
    runs[run_id].set()
    return Response(status_code=204)


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), headers={"Content-Type": CONTENT_TYPE_LATEST})


@app.get("/ready")
async def ready():
    if DRAIN.exists():
        raise HTTPException(503, "Draining")
    return {"ready": True}
