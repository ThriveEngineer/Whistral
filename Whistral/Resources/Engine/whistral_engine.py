#!/usr/bin/env python3
"""Whistral engine — streaming speech-to-text service for the Whistral macOS app.

Wraps Awni Hannun's `voxmlx` (Voxtral Mini 4B Realtime in MLX) and exposes it
over a framed stdin/stdout protocol so the native app can feed microphone audio
and receive live partial transcripts.

Protocol
--------
App -> engine (stdin): frames
    4 bytes  little-endian uint32  frame length N
    1 byte   frame type (0x01 = JSON command, 0x02 = raw audio payload)
    N-1 bytes payload

JSON commands:
    {"cmd": "load",       "model": "<hf repo or path>", "temperature": 0.0}
    {"cmd": "start",      "delayMs": 480}
    {"cmd": "stop"}
    {"cmd": "cancel"}
    {"cmd": "transcribe", "path": "/path/to/audio"}
    {"cmd": "quit"}

Raw audio payloads are float32, mono, 16 kHz, little-endian samples.

Engine -> app (stdout): newline-delimited JSON events
    {"type": "ready"}
    {"type": "modelState", "state": "downloading|loading|ready|error", ...}
    {"type": "sessionStarted"}
    {"type": "partial", "index": n, "text": "...", "segmentText": "..."}
    {"type": "segment", "index": n, "text": "..."}
    {"type": "final", "text": "..."}
    {"type": "cancelled"}
    {"type": "fileTranscript", "text": "...", "path": "..."}
    {"type": "error", "message": "..."}
    {"type": "log", "message": "..."}
"""

import json
import math
import os
import queue
import struct
import sys
import threading
import time

import mlx.core as mx
import numpy as np
from huggingface_hub import snapshot_download
from huggingface_hub.utils.tqdm import tqdm as hf_tqdm
from mistral_common.tokens.tokenizers.base import SpecialTokenPolicy
from mistral_common.tokens.tokenizers.tekken import Tekkenizer

from voxmlx import _build_prompt_tokens, load_model
from voxmlx.audio import SAMPLES_PER_TOKEN, log_mel_spectrogram_step
from voxmlx.cache import RotatingKVCache

N_LEFT_PAD_TOKENS = 32
N_RIGHT_PAD_TOKENS = 17
SLIDING_WINDOW = 8192

FRAME_JSON = 0x01
FRAME_AUDIO = 0x02


_tty_lock = threading.Lock()


def emit(obj: dict) -> None:
    line = json.dumps(obj, ensure_ascii=False)
    with _tty_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def log(message: str) -> None:
    emit({"type": "log", "message": message})


class DownloadTqdm(hf_tqdm):
    """tqdm subclass reporting snapshot_download progress as engine events."""

    _last_emit = 0.0

    def update(self, n=1):
        super().update(n)
        try:
            now = time.monotonic()
            if self.total and (now - DownloadTqdm._last_emit > 0.25 or self.n >= self.total):
                DownloadTqdm._last_emit = now
                emit({
                    "type": "modelState",
                    "state": "downloading",
                    "received": int(self.n),
                    "total": int(self.total),
                })
        except Exception:
            pass


class VoxtralStream:
    """A single streaming dictation session for one model instance."""

    def __init__(self, model, sp, temperature: float):
        self.model = model
        self.sp = sp
        self.temperature = temperature
        self.eos_token_id = sp.eos_id
        self.n_layers = len(model.language_model.layers)

        # --- streaming state (mirrors voxmlx.stream) ---
        self.cache = None
        self.y = None
        self.audio_tail = None
        self.conv1_tail = None
        self.conv2_tail = None
        self.encoder_cache = None
        self.ds_buf = None
        self.pending_audio = np.zeros(0, dtype=np.float32)
        self.audio_embeds = None
        self.n_audio_samples_fed = 0
        self.n_total_decoded = 0
        self.first_cycle = True
        self.prefilled = False
        self.t_cond = None
        self.prompt_len = 0

        # --- session text bookkeeping ---
        self.segment_text = ""   # text of the segment currently being decoded
        self.session_segments = []  # completed segment texts
        self._killed = threading.Event()
        self.prefix_embeds = None  # precomputed text prefix embeddings

    # ------------------------------------------------------------------ setup

    def begin(self, n_delay_tokens: int):
        prompt_tokens, n_delay = _build_prompt_tokens(self.sp, num_delay_tokens=n_delay_tokens)
        self.prompt_len = len(prompt_tokens)
        self.t_cond = self.model.time_embedding(mx.array([n_delay], dtype=mx.float32))
        mx.eval(self.t_cond)
        prompt_ids = mx.array([prompt_tokens])
        self.prefix_embeds = self.model.language_model.embed(prompt_ids)[0]
        mx.eval(self.prefix_embeds)
        self._killed.clear()

    def reset_all_state(self):
        self.audio_tail = None
        self.conv1_tail = None
        self.conv2_tail = None
        self.encoder_cache = None
        self.ds_buf = None
        self.pending_audio = np.zeros(0, dtype=np.float32)
        self.audio_embeds = None
        self.n_audio_samples_fed = 0
        self.n_total_decoded = 0
        self.first_cycle = True
        self.prefilled = False
        self.cache = None
        self.y = None

    # ---------------------------------------------------------------- sampling

    def _sample(self, logits):
        if self.temperature <= 0:
            return mx.argmax(logits[0, -1:], axis=-1).squeeze()
        return mx.random.categorical(logits[0, -1:] / self.temperature).squeeze()

    # ---------------------------------------------------------------- decoding

    def decode_steps(self, embeds, n_to_decode):
        """Decode n_to_decode positions from embeds[0..n_to_decode-1].

        Returns (n_consumed, hit_eos). On EOS, closes the current segment.
        """
        for i in range(n_to_decode):
            token_embed = self.model.language_model.embed(self.y.reshape(1, 1))[0, 0]
            step_embed = (embeds[i] + token_embed)[None, None, :]
            logits = self.model.decode(step_embed, self.t_cond, mask=None, cache=self.cache)
            next_y = self._sample(logits)
            mx.async_eval(next_y)

            token_id = self.y.item()
            if token_id == self.eos_token_id:
                self.cache = None
                self.y = None
                return i, True

            text = self.sp.decode([token_id], special_token_policy=SpecialTokenPolicy.IGNORE)
            self.segment_text += text
            emit({
                "type": "partial",
                "index": len(self.session_segments),
                "segmentText": self.segment_text,
                "text": " ".join([s for s in self.session_segments + [self.segment_text] if s]),
            })

            if i > 0 and i % 256 == 0:
                mx.clear_cache()

            self.y = next_y

        return n_to_decode, False

    # ------------------------------------------------------------------- audio

    def append_audio(self, samples: np.ndarray) -> None:
        self.pending_audio = np.append(self.pending_audio, samples)

    def consume_available_audio(self):
        """Feed pending token-aligned audio through the incremental encoder."""
        n_feed = (len(self.pending_audio) // SAMPLES_PER_TOKEN) * SAMPLES_PER_TOKEN
        if n_feed <= 0:
            return
        if self.first_cycle:
            left_pad = np.zeros(N_LEFT_PAD_TOKENS * SAMPLES_PER_TOKEN, dtype=np.float32)
            chunk = np.concatenate([left_pad, self.pending_audio[:n_feed]])
            self.n_audio_samples_fed += n_feed
            self.pending_audio = self.pending_audio[n_feed:]
            self.first_cycle = False
        else:
            chunk = self.pending_audio[:n_feed]
            self.n_audio_samples_fed += n_feed
            self.pending_audio = self.pending_audio[n_feed:]

        mel, self.audio_tail = log_mel_spectrogram_step(chunk, self.audio_tail)
        new_embeds, self.conv1_tail, self.conv2_tail, self.encoder_cache, self.ds_buf = (
            self.model.encode_step(mel, self.conv1_tail, self.conv2_tail, self.encoder_cache, self.ds_buf)
        )
        if new_embeds is not None:
            mx.eval(new_embeds)
            if self.audio_embeds is not None:
                self.audio_embeds = mx.concatenate([self.audio_embeds, new_embeds])
            else:
                self.audio_embeds = new_embeds

    def pump(self) -> bool:
        """Advance the streaming loop once. Returns True when a segment completed."""
        self.consume_available_audio()

        if self.audio_embeds is None:
            return False

        safe_total = N_LEFT_PAD_TOKENS + self.n_audio_samples_fed // SAMPLES_PER_TOKEN
        n_decodable = min(self.audio_embeds.shape[0], safe_total - self.n_total_decoded)
        if n_decodable <= 0:
            return False

        if not self.prefilled:
            if self.n_total_decoded + self.audio_embeds.shape[0] < self.prompt_len:
                return False

            self.cache = [RotatingKVCache(SLIDING_WINDOW) for _ in range(self.n_layers)]

            prefix_embeds = self.prefix_embeds[: self.prompt_len]
            prefix_embeds = prefix_embeds + self.audio_embeds[: self.prompt_len]
            prefix_embeds = prefix_embeds[None, :, :]

            logits = self.model.decode(prefix_embeds, self.t_cond, "causal", self.cache)
            mx.eval(logits, *[x for c in self.cache for x in (c.keys, c.values)])

            self.y = self._sample(logits)
            mx.async_eval(self.y)

            self.audio_embeds = self.audio_embeds[self.prompt_len:]
            self.n_total_decoded = self.prompt_len
            self.prefilled = True

            n_decodable = min(
                self.audio_embeds.shape[0], safe_total - self.n_total_decoded
            )
            if n_decodable <= 0:
                return False

        n_consumed, hit_eos = self.decode_steps(self.audio_embeds, n_decodable)
        self.n_total_decoded += n_consumed

        if self.audio_embeds.shape[0] > n_consumed:
            self.audio_embeds = self.audio_embeds[n_consumed:]
        else:
            self.audio_embeds = None

        if hit_eos:
            segment = self.segment_text
            self.session_segments.append(segment)
            self.segment_text = ""
            self.reset_all_state()
            return True

        return False

    # ------------------------------------------------------------------- flush

    def flush(self) -> str:
        """Finish the session: feed right padding, decode everything remaining."""
        self._killed.clear()
        right_pad = np.zeros(N_RIGHT_PAD_TOKENS * SAMPLES_PER_TOKEN, dtype=np.float32)
        flush_chunk = np.concatenate([self.pending_audio, right_pad])
        if self.cache is not None and self.y is not None:
            mel, self.audio_tail = log_mel_spectrogram_step(flush_chunk, self.audio_tail)
            new_embeds, self.conv1_tail, self.conv2_tail, self.encoder_cache, self.ds_buf = (
                self.model.encode_step(mel, self.conv1_tail, self.conv2_tail, self.encoder_cache, self.ds_buf)
            )
            if new_embeds is not None:
                mx.eval(new_embeds)
                if self.audio_embeds is not None:
                    self.audio_embeds = mx.concatenate([self.audio_embeds, new_embeds])
                else:
                    self.audio_embeds = new_embeds
            if self.audio_embeds is not None and self.audio_embeds.shape[0] > 0:
                self.decode_steps(self.audio_embeds, self.audio_embeds.shape[0])

        # Flush the last pending token
        if self.y is not None:
            token_id = self.y.item()
            if token_id != self.eos_token_id:
                text = self.sp.decode([token_id], special_token_policy=SpecialTokenPolicy.IGNORE)
                self.segment_text += text
                self.y = None

        if self.segment_text:
            self.session_segments.append(self.segment_text)
            self.segment_text = ""

        final = " ".join(s for s in self.session_segments if s)
        self.reset_all_state()
        self.session_segments = []
        return final

    def cancel(self) -> None:
        self.reset_all_state()
        self.session_segments = []
        self.segment_text = ""
        self._killed.set()

    def close(self) -> None:
        self._killed.set()


class Engine:
    """Loads the model once and serializes sessions."""

    def __init__(self):
        self.model = None
        self.sp = None
        self.config = None
        self.temperature = 0.0
        self.model_id = None
        self.lock = threading.RLock()
        self.prefix_cache = {}

    # ------------------------------------------------------------- model load

    def _download(self, model_id: str) -> str:
        return str(snapshot_download(
            model_id,
            allow_patterns=[
                "consolidated.safetensors",
                "model*.safetensors",
                "model.safetensors.index.json",
                "params.json",
                "config.json",
                "tekken.json",
            ],
            tqdm_class=DownloadTqdm,
        ))

    def load(self, model_id: str, temperature: float) -> None:
        with self.lock:
            if self.model is not None and self.model_id == model_id:
                return
            emit({"type": "modelState", "state": "loading", "model": model_id})
            local_path = self._download(model_id)
            model, config = load_model(local_path)
            sp = Tekkenizer.from_file(str(local_path / "tekken.json"))
            self.model, self.sp, self.config = model, sp, config
            self.model_id = model_id
            self.temperature = temperature
            self.prefix_cache = {}
            emit({"type": "modelState", "state": "ready", "model": model_id})

    # ---------------------------------------------------------------- session

    def _stream_session(self, audio_q: queue.Queue, ctl: dict, n_delay_tokens: int):
        """Runs a full session on a worker thread."""
        try:
            stream = VoxtralStream(self.model, self.sp, self.temperature)
            stream.begin(n_delay_tokens)
            emit({"type": "sessionStarted"})

            right_pad_pending = False
            while True:
                if ctl.get("cancel"):
                    stream.cancel()
                    emit({"type": "cancelled"})
                    return
                if ctl.get("flush"):
                    break
                got = False
                try:
                    while True:
                        chunk = audio_q.get_nowait()
                        if chunk is None:  # end-of-audio marker
                            right_pad_pending = True
                        else:
                            stream.append_audio(chunk)
                        got = True
                except queue.Empty:
                    pass
                if right_pad_pending:
                    break
                if not got:
                    time.sleep(0.01)
                # advance decoding
                try:
                    if stream.pump():
                        emit({
                            "type": "segment",
                            "index": len(stream.session_segments),
                            "text": stream.session_segments[-1],
                        })
                except Exception as exc:  # noqa: BLE001
                    emit({"type": "error", "message": f"Engine streaming error: {exc}"})
                    stream.cancel()
                    ctl["abort"] = True
                    return

            # Flush: consume any remaining queued audio first
            try:
                while True:
                    chunk = audio_q.get_nowait()
                    if chunk is not None:
                        stream.append_audio(chunk)
            except queue.Empty:
                pass

            final = stream.flush()
            emit({"type": "final", "text": final})
        except Exception as exc:  # noqa: BLE001
            emit({"type": "error", "message": f"Engine session error: {exc}"})


ENGINE = Engine()


class StreamRunner:
    """Single in-flight streaming session."""

    def __init__(self, engine: Engine):
        self.engine = engine
        self.audio_q: queue.Queue = queue.Queue(maxsize=4096)
        self.thread = None
        self.ctl = {"cancel": False, "flush": False, "abort": False}
        self.active = False

    def start(self, n_delay_tokens: int) -> None:
        self.ctl = {"cancel": False, "flush": False, "abort": False}
        self.active = True
        self.thread = threading.Thread(
            target=self.engine._stream_session,
            args=(self.audio_q, self.ctl, n_delay_tokens),
            daemon=True,
        )
        self.thread.start()

    def offer_audio(self, samples: np.ndarray):
        try:
            self.audio_q.put_nowait(samples)
        except queue.Full:
            pass  # never block the mic thread; drop oldest if needed
        else:
            return
        try:
            self.audio_q.get_nowait()
            self.audio_q.put_nowait(samples)
        except (queue.Empty, queue.Full):
            pass

    def stop(self, sync_timeout: float = 60.0) -> None:
        if not self.active:
            emit({"type": "final", "text": ""})
            return
        self.ctl["flush"] = True
        try:
            self.audio_q.put_nowait(None)  # end-of-audio marker
        except queue.Full:
            pass
        if self.thread:
            self.thread.join(timeout=sync_timeout)
        self.active = False

    def cancel(self) -> None:
        if not self.active:
            emit({"type": "cancelled"})
            return
        self.ctl["cancel"] = True
        if self.thread:
            self.thread.join(timeout=15.0)
        self.active = False


RUNNER = None


def handle_command(cmd: dict, runner: StreamRunner) -> bool:
    """Returns False when the engine should quit."""
    global RUNNER
    action = cmd.get("cmd")

    if action == "load":
        try:
            ENGINE.load(cmd.get("model", "mlx-community/Voxtral-Mini-4B-Realtime-6bit"),
                        float(cmd.get("temperature", 0.0)))
        except Exception as exc:  # noqa: BLE001
            emit({"type": "modelState", "state": "error", "message": str(exc)[:400]})
            emit({"type": "error", "message": f"Model load failed: {exc}"})

    elif action == "start":
        delay_ms = int(cmd.get("delayMs", 480))
        delay_ms = max(80, min(2400, delay_ms - (delay_ms % 80)))
        n_delay_tokens = delay_ms // 80
        if RUNNER is not None and RUNNER.active:
            emit({"type": "error", "message": "A session is already running"})
        else:
            RUNNER = StreamRunner(ENGINE)
            RUNNER.start(n_delay_tokens)

    elif action == "stop":
        if RUNNER is not None:
            RUNNER.stop()
            RUNNER = None

    elif action == "cancel":
        if RUNNER is not None:
            RUNNER.cancel()
            RUNNER = None

    elif action == "audio":
        pass  # handled at the frame layer

    elif action == "transcribe":
        path = cmd.get("path", "")
        try:
            from voxmlx import transcribe as vx_transcribe
            text = vx_transcribe(path, model_path=ENGINE.model_id, temperature=ENGINE.temperature)
            emit({"type": "fileTranscript", "path": path, "text": text})
        except Exception as exc:  # noqa: BLE001
            emit({"type": "error", "message": f"File transcription failed: {exc}"})

    elif action == "quit":
        return False

    else:
        emit({"type": "error", "message": f"Unknown command: {action}"})
    return True


def read_frames():
    """Parse framed input from stdin and dispatch."""
    global RUNNER
    from voxmlx.audio import SAMPLES_PER_TOKEN as _SPT  # noqa: F401

    while True:
        header = sys.stdin.buffer.read(5)
        if not header or len(header) < 5:
            # App is gone; stop cleanly.
            if RUNNER is not None:
                RUNNER.cancel()
            return
        (length,) = struct.unpack("<I", header[:4])
        ftype = header[4]
        payload = sys.stdin.buffer.read(max(0, length - 1))
        if ftype == FRAME_JSON:
            try:
                cmd = json.loads(payload.decode("utf-8"))
            except json.JSONDecodeError:
                emit({"type": "error", "message": "Malformed JSON command"})
                continue
            if not handle_command(cmd, RUNNER):
                return
        elif ftype == FRAME_AUDIO:
            samples = np.frombuffer(payload, dtype="<f4")
            if RUNNER is not None and RUNNER.active and samples.size:
                RUNNER.offer_audio(samples)


def main() -> None:
    # Keep the GPU wired to the process for snappier session starts.
    os.environ.setdefault("MLX_METAL_PRECOMPILE", "1")
    emit({"type": "ready"})
    try:
        read_frames()
    finally:
        sys.exit(0)


if __name__ == "__main__":
    main()
