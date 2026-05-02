#!/usr/bin/env python3
"""Cadence simulator: word_timings.json + profile.yaml → events.json.

Models the streaming behavior of an ASR engine — most importantly the
session_reset semantics. iOS SFSpeechRecognizer (and our SpeechService
auto-restart wrapper around speech_to_text) ends a session whenever the
speaker is silent for >~1.5s OR the session has been alive for >50s.
After each reset the *text accumulator clears* (cumulative-within-session
contract): the first transcript event of the new session starts from
empty, even though the speaker continues mid-script.

V2 matcher's _matchStartOffset doesn't reset across sessions, so it ends
up looking for the new session's short fresh text in a small window
ahead of the *previous* session's last final position — that's the
"V2 stuck after silence" failure mode.

Usage:
    python cadence/simulator.py jfk ios-on-device-15
    python cadence/simulator.py jfk clean-passthrough
"""
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

REPO = Path(__file__).resolve().parents[2]
PROFILES_DIR = Path(__file__).resolve().parent / "profiles"
WT_DIR = REPO / "benchmark" / "results" / "word_timings"
OUT_DIR = REPO / "benchmark" / "results" / "events"


@dataclass
class Word:
    word: str
    start_ms: int
    end_ms: int


def load_words(stem: str) -> tuple[list[Word], dict]:
    p = WT_DIR / f"{stem}.json"
    d = json.loads(p.read_text())
    words = [Word(w["word"], int(w["start_ms"]), int(w["end_ms"])) for w in d["words"]]
    return words, d


def load_profile(name: str) -> dict:
    return yaml.safe_load((PROFILES_DIR / f"{name}.yaml").read_text())


# ---------------------------------------------------------------------------
# Session segmentation
# ---------------------------------------------------------------------------

def split_into_sessions(words: list[Word], profile: dict) -> list[list[Word]]:
    """Group words into sessions according to silence_trigger_ms and
    forced_restart_s in the profile."""
    sr = profile.get("session_reset", {}) or {}
    silence_ms = sr.get("silence_trigger_ms")
    forced_s = sr.get("forced_restart_s")

    if silence_ms is None and forced_s is None:
        return [words]

    sessions: list[list[Word]] = [[]]
    session_start_ms = words[0].start_ms if words else 0

    for i, w in enumerate(words):
        if not sessions[-1]:
            sessions[-1].append(w)
            session_start_ms = w.start_ms
            continue
        prev = sessions[-1][-1]
        gap_ms = w.start_ms - prev.end_ms
        elapsed_s = (w.start_ms - session_start_ms) / 1000.0

        new_session = False
        if silence_ms is not None and gap_ms >= silence_ms:
            new_session = True
        elif forced_s is not None and elapsed_s >= forced_s:
            new_session = True

        if new_session:
            sessions.append([w])
            session_start_ms = w.start_ms
        else:
            sessions[-1].append(w)

    return [s for s in sessions if s]


# ---------------------------------------------------------------------------
# Profile renderers
# ---------------------------------------------------------------------------

def render_clean_passthrough(words: list[Word], profile: dict) -> list[dict]:
    """Each word = one final event at its start_ms with text = that word."""
    events = [
        {
            "event_type": "transcript",
            "session_id": 0,
            "time_ms": w.start_ms,
            "text": w.word,
            "is_final": True,
        }
        for w in words
    ]
    return events


def render_ios_like(words: list[Word], profile: dict) -> list[dict]:
    """Cumulative-within-session partials at fixed cadence. Final at end of
    each session. session_reset between sessions (text accumulator clears)."""
    sessions = split_into_sessions(words, profile)
    sr = profile.get("session_reset", {}) or {}
    silence_ms = sr.get("silence_trigger_ms", 1500)
    delay_ms = sr.get("silence_restart_delay_ms", 150)
    partial_interval_ms = profile.get("partial_interval_ms", 80)
    emit_partials = profile.get("emit_partials", True)

    events: list[dict] = []
    next_session_id = 0

    for si, session in enumerate(sessions):
        sid = next_session_id
        next_session_id += 1

        if emit_partials:
            # Emit partials at fixed cadence covering [first.start_ms, last.end_ms].
            t = session[0].start_ms
            end_t = session[-1].end_ms
            while t <= end_t:
                # Cumulative text = all words whose end_ms <= t (within this session).
                visible = [w for w in session if w.end_ms <= t]
                text = " ".join(w.word for w in visible)
                # Skip empty leading partials.
                if text:
                    events.append({
                        "event_type": "transcript",
                        "session_id": sid,
                        "time_ms": t,
                        "text": text,
                        "is_final": False,
                    })
                t += partial_interval_ms

        # Emit the session-final at last word's end_ms.
        events.append({
            "event_type": "transcript",
            "session_id": sid,
            "time_ms": session[-1].end_ms,
            "text": " ".join(w.word for w in session),
            "is_final": True,
        })

        # If there's a next session, inject session_reset between them.
        if si + 1 < len(sessions):
            reset_t = sessions[si + 1][0].start_ms - delay_ms
            reset_t = max(reset_t, session[-1].end_ms + 1)
            events.append({
                "event_type": "session_reset",
                "time_ms": reset_t,
                "session_id_old": sid,
                "session_id_new": next_session_id,
                "reason": "silence-restart",
            })

    events.sort(key=lambda e: e["time_ms"])
    return events


def render(words: list[Word], profile: dict) -> list[dict]:
    if profile.get("one_final_per_word"):
        return render_clean_passthrough(words, profile)
    return render_ios_like(words, profile)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("stem")
    ap.add_argument("profile")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()

    words, wt_meta = load_words(args.stem)
    profile = load_profile(args.profile)
    events = render(words, profile)

    payload: dict[str, Any] = {
        "clip_id": args.stem,
        "cadence_profile": args.profile,
        "seed": args.seed,
        "text_contract": "cumulative-within-session",
        "audio_duration_ms": wt_meta["audio_duration_ms"],
        "events": events,
    }

    out = args.out or (OUT_DIR / f"{args.stem}__{args.profile}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2) + "\n")

    sessions = sum(1 for e in events if e["event_type"] == "session_reset") + 1
    transcripts = sum(1 for e in events if e["event_type"] == "transcript")
    finals = sum(1 for e in events
                 if e["event_type"] == "transcript" and e.get("is_final"))
    print(f"wrote {out.relative_to(REPO)}  "
          f"({transcripts} transcript events, {finals} finals, "
          f"{sessions} sessions)")


if __name__ == "__main__":
    main()
