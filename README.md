# VideoMerger

A tiny macOS app for merging multiple mp4 files without touching the original bitrate or content.

Built because I kept forgetting the exact `ffmpeg` incantation for lossless concatenation. This just wraps it in a small drag-and-drop UI.

## How it works

- Drop in multiple mp4 files, reorder them, hit merge
- Before merging, it probes every file with `ffprobe` (video codec, resolution, frame rate, pixel format, audio codec, sample rate, channels) and only proceeds if all inputs match
- If they match, it runs `ffmpeg -f concat -c copy` — a pure stream copy, no re-encoding, no quality loss
- If they don't match, it tells you exactly which parameter differs and stops. It will **not** silently re-encode on your behalf

This check matters: ffmpeg's concat demuxer does not itself validate that inputs are compatible in `-c copy` mode. Feeding it mismatched files (e.g. different resolutions) exits with status 0 and produces a corrupted file — no error at all. Hence the ffprobe pre-flight check.

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
