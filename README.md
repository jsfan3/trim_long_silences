by [Francesco Galgani](https://www.informatica-libera.net/), license [CC0](https://creativecommons.org/publicdomain/zero/1.0/)

# trim_long_silences

A Bash script for Linux that shortens long silent sections in an MP4 file while cutting audio and video at the exact same points.

If a silence is longer than the configured threshold, the script keeps only the first part of that silence and removes the rest. This means the output video is actually shorter than the input, with both audio and video trimmed consistently.

## Features

- Detects silence using `ffmpeg`
- Keeps audio and video perfectly aligned
- Shortens every silence longer than the configured limit
- Works on MP4 files with one main video stream and one main audio stream
- Uses temporary segments plus concatenation instead of a giant `filter_complex`, which makes it more robust on long files

## Requirements

- Bash
- `ffmpeg`
- `ffprobe`
- `awk`

On Debian, Ubuntu, or Linux Mint:

```bash
sudo apt update
sudo apt install ffmpeg
```

## Usage

```bash
./trim_long_silences_fixed.sh input.mp4 output.mp4 [max_silence] [noise_threshold]
```

## Examples

Default behavior:

```bash
./trim_long_silences_fixed.sh input.mp4 output.mp4
```

Keep at most 2 seconds of each long silence, with a custom detection threshold:

```bash
./trim_long_silences_fixed.sh input.mp4 output.mp4 2 -35dB
```

Speed up encoding on long videos:

```bash
VIDEO_PRESET=ultrafast ./trim_long_silences_fixed.sh input.mp4 output.mp4
```

## Arguments

- `input.mp4`: source file
- `output.mp4`: output file
- `max_silence`: maximum silence to keep for each long silent section. Default: `2`
- `noise_threshold`: silence detection threshold passed to `ffmpeg`. Default: `-35dB`

## Optional environment variables

- `VIDEO_PRESET`: x264 preset for temporary segments. Default: `veryfast`
- `VIDEO_CRF`: x264 CRF value. Default: `18`
- `AUDIO_BITRATE`: AAC bitrate for temporary segments. Default: `96k`

## How it works

1. The script analyzes the first audio stream with `ffmpeg` and `silencedetect`.
2. It extracts the silent ranges.
3. For each silence longer than the configured limit, it keeps only the first `max_silence` seconds.
4. It exports the kept ranges as temporary segments.
5. It concatenates those segments into the final MP4.

## Notes

- The file is re-encoded. This is intentional, because frame-accurate cutting with synchronized audio/video is much more reliable this way.
- The script is designed for practical editing, not sample-perfect audio mastering.
- Tiny timing differences can still appear because of codec framing and AAC padding.
- Silence detection quality depends on the `noise_threshold` value and on the source material.

## Tested on

- Linux Mint 22
- FFmpeg 6.x

## License

This project is released under [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
