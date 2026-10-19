"""Industrial sensor simulator for the RTI x AML demo.

Sends JSON telemetry to a Fabric Eventstream *Custom endpoint* (Event Hub
compatible). Four sensors per device:

    temperature_c   <- the ML target (predicted 15 min ahead)
    humidity_pct    <- inversely correlated with temperature
    pressure_bar    <- driven by the machine load
    vibration_mm_s  <- observable proxy of the machine load

The physics are deliberately *learnable*: temperature follows a first-order
lag (tau = 300 s) towards a target driven by a slow cyclical ambient and by a
mean-reverting load. Because the load is visible through vibration and
pressure, and the thermal response is slow, t+15 min is genuinely predictable
from the last 30 minutes -- which is exactly what the AML model does.

Usage
-----
    python sensor_producer.py --backfill-minutes 90 --duration-minutes 60

`--backfill-minutes` first replays history with past timestamps so the
training set is usable immediately instead of after an hour of waiting.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import random
import sys
from datetime import datetime, timedelta, timezone

from azure.eventhub import EventData
from azure.eventhub.aio import EventHubProducerClient
from dotenv import load_dotenv

# --- tuning constants -------------------------------------------------------
AMBIENT_PERIOD_S = 1800.0   # 30 min main cycle
AMBIENT_HARMONIC_S = 420.0  # 7 min harmonic
THERMAL_TAU_S = 300.0       # first-order thermal response
LOAD_REVERSION_S = 900.0    # mean reversion time of the machine load


class Device:
    """One simulated machine.

    thermal_gain and ambient_offset exist for P7. The model learned the
    relationship between load and temperature; changing the gain BREAKS that
    relationship, which makes the observed error climb. The ambient offset
    shifts the inputs themselves, which is what data drift detects. Using both
    triggers the two independent detectors of the demo from a single event.
    """

    def __init__(
        self,
        device_id: str,
        seed: int,
        thermal_gain: float = 25.0,
        ambient_offset: float = 0.0,
    ) -> None:
        self.device_id = device_id
        self.rng = random.Random(seed)
        self.phase = self.rng.uniform(0.0, 2.0 * math.pi)
        self.thermal_gain = thermal_gain
        self.ambient_base = self.rng.uniform(18.0, 24.0) + ambient_offset
        self.load = self.rng.uniform(0.3, 0.7)
        self.pressure = self.rng.uniform(4.5, 5.5)
        self.temperature = self.ambient_base + self.thermal_gain * self.load

    def step(self, t: float, dt: float) -> dict:
        rng = self.rng
        sqrt_dt = math.sqrt(dt)

        ambient = (
            self.ambient_base
            + 6.0 * math.sin(2.0 * math.pi * t / AMBIENT_PERIOD_S + self.phase)
            + 1.5 * math.sin(2.0 * math.pi * t / AMBIENT_HARMONIC_S + self.phase)
        )

        # mean-reverting load in [0, 1]
        self.load += -(self.load - 0.5) * dt / LOAD_REVERSION_S + 0.03 * sqrt_dt * rng.gauss(0.0, 1.0)
        self.load = min(1.0, max(0.0, self.load))

        # first-order thermal response towards the load-driven target
        target = ambient + self.thermal_gain * self.load
        self.temperature += (target - self.temperature) * dt / THERMAL_TAU_S
        self.temperature += 0.05 * sqrt_dt * rng.gauss(0.0, 1.0)

        # pressure tracks the load, with its own inertia
        p_target = 4.0 + 2.5 * self.load
        self.pressure += (p_target - self.pressure) * dt / 120.0
        self.pressure += 0.02 * sqrt_dt * rng.gauss(0.0, 1.0)

        vibration = 0.5 + 6.0 * (self.load ** 1.5) + 0.15 * rng.gauss(0.0, 1.0)
        humidity = 70.0 - 1.2 * (self.temperature - 20.0) + 0.8 * rng.gauss(0.0, 1.0)

        return {
            "temperature_c": round(self.temperature, 3),
            "humidity_pct": round(min(95.0, max(10.0, humidity)), 3),
            "pressure_bar": round(max(0.0, self.pressure), 3),
            "vibration_mm_s": round(max(0.0, vibration), 3),
        }


def build_payload(device: Device, t: float, dt: float, ts: datetime) -> dict:
    reading = device.step(t, dt)
    reading["timestamp"] = ts.isoformat().replace("+00:00", "Z")
    reading["device_id"] = device.device_id
    return reading


async def send(producer: EventHubProducerClient, payloads: list[dict]) -> None:
    """Send payloads, splitting into batches that respect the size limit."""
    batch = await producer.create_batch()
    for payload in payloads:
        event = EventData(json.dumps(payload))
        try:
            batch.add(event)
        except ValueError:
            await producer.send_batch(batch)
            batch = await producer.create_batch()
            batch.add(event)
    if len(batch) > 0:
        await producer.send_batch(batch)


async def run(args: argparse.Namespace, conn_str: str, eventhub_name: str | None) -> None:
    devices = [
        Device(
            f"machine-{i + 1:02d}",
            seed=1000 + i,
            thermal_gain=args.thermal_gain,
            ambient_offset=args.ambient_offset,
        )
        for i in range(args.devices)
    ]
    dt = 1.0 / args.rate

    kwargs = {"conn_str": conn_str}
    if eventhub_name:
        kwargs["eventhub_name"] = eventhub_name

    async with EventHubProducerClient.from_connection_string(**kwargs) as producer:
        t = 0.0
        now = datetime.now(timezone.utc)

        # ---- 1. backfill: replay history with past timestamps ----
        if args.backfill_minutes > 0:
            start = now - timedelta(minutes=args.backfill_minutes)
            steps = int(args.backfill_minutes * 60 * args.rate)
            print(f"backfilling {args.backfill_minutes} min "
                  f"({steps * args.devices} events) ...", flush=True)
            buffer: list[dict] = []
            for i in range(steps):
                ts = start + timedelta(seconds=i * dt)
                for device in devices:
                    buffer.append(build_payload(device, t, dt, ts))
                t += dt
                if len(buffer) >= 2000:
                    await send(producer, buffer)
                    buffer.clear()
            if buffer:
                await send(producer, buffer)
            print("backfill done", flush=True)

        # ---- 2. live stream ----
        deadline = None
        if args.duration_minutes > 0:
            deadline = datetime.now(timezone.utc) + timedelta(minutes=args.duration_minutes)
        print(f"streaming {args.devices} devices at {args.rate} msg/s "
              f"(Ctrl+C to stop) ...", flush=True)

        sent = 0
        while deadline is None or datetime.now(timezone.utc) < deadline:
            ts = datetime.now(timezone.utc)
            payloads = [build_payload(device, t, dt, ts) for device in devices]
            await send(producer, payloads)
            sent += len(payloads)
            t += dt
            if sent % (args.devices * 30) == 0:
                print(f"  {sent} events sent, last temp="
                      f"{payloads[0]['temperature_c']:.2f} C", flush=True)
            await asyncio.sleep(dt)


def main() -> int:
    load_dotenv()

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--devices", type=int, default=4)
    parser.add_argument("--rate", type=float, default=1.0, help="messages per second per device")
    parser.add_argument("--backfill-minutes", type=int, default=0)
    parser.add_argument("--duration-minutes", type=int, default=0, help="0 = run until Ctrl+C")
    parser.add_argument(
        "--thermal-gain",
        type=float,
        default=25.0,
        help="P7 regime shift: temperature rise at full load, in degrees (default 25). "
             "Raise to 40 to break the load/temperature relationship the model learned.",
    )
    parser.add_argument(
        "--ambient-offset",
        type=float,
        default=0.0,
        help="P7 regime shift: degrees added to the ambient baseline (default 0). "
             "Shifts the input distribution, which is what data drift detects.",
    )
    args = parser.parse_args()

    conn_str = os.getenv("EVENTSTREAM_CONNECTION_STRING")
    if not conn_str:
        print("EVENTSTREAM_CONNECTION_STRING is not set. "
              "Copy .env.example to .env and paste the Eventstream custom endpoint "
              "connection string.", file=sys.stderr)
        return 1
    eventhub_name = os.getenv("EVENTSTREAM_EVENTHUB_NAME") or None

    try:
        asyncio.run(run(args, conn_str, eventhub_name))
    except KeyboardInterrupt:
        print("\nstopped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
