#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Generate two nonpersonal WAV/LRC fixtures for the isolated UI simulator."""
import argparse
from pathlib import Path
import struct
import wave

TRACKS = (("UIA-Synthetic-00", 440), ("UIL-Synthetic-01", 550))
RATE = 8000
SECONDS = 600


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_dir", type=Path, help="an empty local directory")
    args = parser.parse_args()
    output = args.output_dir.expanduser().resolve()
    if output.exists() and any(output.iterdir()):
        parser.error("output directory must be empty; existing media is never replaced")
    output.mkdir(parents=True, exist_ok=True)
    for title, freq in TRACKS:
        target = output / f"{title}.wav"
        with wave.open(str(target), "wb") as writer:
            writer.setnchannels(1)
            writer.setsampwidth(2)
            writer.setframerate(RATE)
            for start in range(0, RATE * SECONDS, RATE):
                samples = bytearray()
                for n in range(start, min(start + RATE, RATE * SECONDS)):
                    phase = n * freq * 100 // RATE % 100
                    value = (phase if phase < 50 else 100 - phase) * 240 - 6000
                    samples.extend(struct.pack("<h", value))
                writer.writeframes(samples)
        print(f"{target.name}: {target.stat().st_size} bytes")
    lyrics = output / "UIL-Synthetic-01.lrc"
    lyrics.write_text("[00:00.00]Synthetic lyric\n[00:02.00]Another synthetic line\n", encoding="utf-8")
    print(f"{lyrics.name}: {lyrics.stat().st_size} bytes")


if __name__ == "__main__":
    main()
