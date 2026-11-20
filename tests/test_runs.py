import asyncio
import unittest

from app.main import ACTIVE, run_graph, graph


class Runs(unittest.IsolatedAsyncioTestCase):
    async def test_six_real_runs(self):
        events = [asyncio.Event() for _ in range(6)]
        tasks = [asyncio.create_task(run_graph(event)) for event in events]
        await asyncio.sleep(.1)
        self.assertEqual(ACTIVE.collect()[0].samples[0].value, 6)
        for event in events:
            event.set()
        await asyncio.gather(*tasks)
        self.assertEqual(ACTIVE.collect()[0].samples[0].value, 0)

    async def test_cancel_and_error(self):
        task = asyncio.create_task(run_graph(asyncio.Event()))
        await asyncio.sleep(.05)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task
        self.assertEqual(ACTIVE.collect()[0].samples[0].value, 0)
        with self.assertRaises(TimeoutError):
            await run_graph(asyncio.Event(), timeout=.02)
        self.assertEqual(ACTIVE.collect()[0].samples[0].value, 0)
