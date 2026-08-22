# VideoMerger

A tiny macOS app for merging multiple mp4 files without touching the original bitrate or content.

Built because I kept forgetting the exact `ffmpeg` incantation for lossless concatenation. This just wraps it in a small drag-and-drop UI.

## How it works

- Drop in multiple mp4 files, reorder them, hit merge
- Before merging, it probes every file with `ffprobe` (video codec, resolution, frame rate, pixel format, audio codec, sample rate, channels) and only proceeds if all inputs match
- If they match, it runs `ffmpeg -f concat -c copy` — a pure stream copy, no re-encoding, no quality loss
- If they don't match, it tells you exactly which parameter differs and stops. It will **not** silently re-encode on your behalf

This check matters: ffmpeg's concat demuxer does not itself validate that inputs are compatible in `-c copy` mode. Feeding it mismatched files (e.g. different resolutions) exits with status 0 and produces a corrupted file — no error at all. Hence the ffprobe pre-flight check.

## Silence / dead-air removal

Added for a specific use case: a recorded livestream where the connection dropped briefly, leaving a stretch of frozen video, looping audio, then dead silence.

- **Detect**: runs ffmpeg's `silencedetect` filter per file (audio-only, `-vn`, so it doesn't waste time decoding video) and lists the silent ranges as checkboxes, excluding ranges that touch the very start/end of the file (those are normal pre-roll/post-roll quiet, not dropouts). Each range has a play button that previews it (plus 2s of context) via AVKit before you decide whether to remove it.
- **Extend for freezes**: a stream reconnect often freezes the picture and loops the audio for a second or two *before* it actually goes silent — plain silence detection misses that lead-in. So each detected range gets checked against ffmpeg's `freezedetect` filter in a small local window around it; if a freeze overlaps or sits right next to the silence, the range is extended to cover both. (An earlier version tried to find this by cross-referencing audio fingerprints against the pre-silence audio, on the theory that a dropout replays already-played content — that turned out to be unreliable on musical content, which has enough internal repetition — chorus, drum patterns — to produce false matches. `freezedetect` targets the actual visual symptom directly and needs no such guessing.)
- **Remove**: outputs a *new* file, never overwrites the original. Cuts are made with the same "don't touch the bitrate" philosophy as the merge feature — only the few seconds immediately around each cut point get re-encoded (to land exactly on the requested timestamp instead of the nearest keyframe), and everything else is `-c copy`. Currently limited to H.264/AAC sources.

## Requirements

- macOS 14+
- [ffmpeg](https://ffmpeg.org/) installed via Homebrew (`brew install ffmpeg`) — looked up at `/opt/homebrew/bin`, `/usr/local/bin`, or `/usr/bin`

## Build

```bash
brew install xcodegen  # if you don't have it
cd app
xcodegen generate
open VideoMerger.xcodeproj
```

Build and run from Xcode. No code signing/notarization is set up — this is a personal-use tool, not distributed as a signed binary.
