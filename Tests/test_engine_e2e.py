#!/usr/bin/env python3
"""Manual E2E test of the whistral_engine sidecar protocol.

Spawns the sidecar, sends: load -> start -> float32 audio frames -> stop,
and prints every NDJSON event received.
"""
import json
import math
import os
import struct
import subprocess
import sys
import threading
import time

VENVPY = os.path.expanduser("~/Library/Application Support/Whistral/venv/bin/python")
ENGINE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "Whistral", "Resources", "Engine", "whistral_engine.py")

proc = subprocess.Popen(
    [VENVPY, ENGINE],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    bufsize=0,
)

def send_frame(ftype, payload):
    # length includes the 1-byte type (matches SidecarEngineClient.writeFrame)
    proc.stdin.write(struct.pack("<I", len(payload) + 1) + bytes([ftype]) + payload)
    proc.stdin.flush()

def send_cmd(obj):
    send_frame(0x01, json.dumps(obj).encode())

def send_audio(samples):
    send_frame(0x02, struct.pack("<%df" % len(samples), *samples))

events = []
reader_done = threading.Event()

def reader():
    # Engine emits newline-delimited JSON on stdout.
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            ev = {"raw": line[:400]}
        events.append(ev)
        print("EVENT:", json.dumps(ev)[:400], flush=True)
    reader_done.set()

t = threading.Thread(target=reader, daemon=True)
t.start()

time.sleep(1.0)
send_cmd({"cmd": "load"})
print("==> load sent", flush=True)

# Wait for ready (model state = ready) up to 15 min
deadline = time.time() + 900
ready = False
while time.time() < deadline:
    if any(e.get("event") == "ready" for e in events):
        ready = True
        break
    if any(e.get("event") in ("error",) for e in events):
        print("FATAL error during load; aborting")
        proc.kill(); sys.exit(1)
    time.sleep(0.5)
if not ready:
    print("TIMEOUT waiting for ready"); proc.kill(); sys.exit(1)

send_cmd({"cmd": "start", "delayMs": 300})
time.sleep(2.0)

# Send 3 seconds of a 440 Hz tone + envelope, 16 kHz
sr = 16000
for i in range(3 * sr // 3200):  # 100 ms chunks of 1600 samples
    chunk = [0.5 * math.sin(2 * math.pi * 440 * (i * 1600 + j) / sr) for j in range(1600)]
    send_audio(chunk)
    time.sleep(0.02)
send_cmd({"cmd": "stop"})
print("==> stop sent", flush=True)

deadline = time.time() + 120
final = None
while time.time() < deadline:
    if any(e.get("event") == "final" for e in events):
        final = next(e for e in events if e.get("event") == "final")
        break
    time.sleep(0.5)

send_cmd({"cmd": "quit"})
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()

print("\n=== Result ===")
print("final:", json.dumps(final) if final else "NOT RECEIVED")
print("total events:", len(events))
sys.exit(0 if final is not None else 1)
