import asyncio
import unittest

from app.main import ACTIVE, graph, stream_run


class Streams(unittest.IsolatedAsyncioTestCase):
    async def test_six_open_streams_and_release(self):
        gate = asyncio.Event()
        streams = [stream_run(graph, {"backend": "probe", "gate": gate, "pace": 0}) for _ in range(6)]
        for event in await asyncio.gather(*(anext(s) for s in streams)):
            self.assertIn("event: delta", event)
        self.assertEqual(ACTIVE.collect()[0].samples[0].value, 6)
        await streams.pop().aclose()
        self.assertEqual(ACTIVE.collect()[0].samples[0].value, 5)
        gate.set()
        for s in streams:
            self.assertEqual([frame async for frame in s], ["event: done\ndata: {}\n\n"])
        self.assertEqual(ACTIVE.collect()[0].samples[0].value, 0)

    async def test_failed_graph_releases_gauge(self):
        class Broken:
            async def astream(self, *args, **kwargs):
                yield "started"
                raise ValueError("model error")
        with self.assertRaisesRegex(ValueError, "model error"):
            async for _ in stream_run(Broken(), {}):
                pass
        self.assertEqual(ACTIVE.collect()[0].samples[0].value, 0)
