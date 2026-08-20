import argparse
import json
import pathlib
import sys
import time
import wave


def parse_args():
    parser = argparse.ArgumentParser(
        description="Capture a Windows output device through WASAPI loopback."
    )
    parser.add_argument("--module-dir", action="append", default=[])
    parser.add_argument("--output", required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--sample-rate", type=int, default=48000)
    parser.add_argument("--channels", type=int, default=2)
    parser.add_argument("--block-frames", type=int, default=1024)
    parser.add_argument(
        "--speaker-name",
        help="Exact or case-insensitive substring of the Windows speaker to capture; default is the current output device.",
    )
    return parser.parse_args()


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2), encoding="utf-8")
    temporary.replace(path)


def select_speaker(sc, requested_name):
    if not requested_name:
        return sc.default_speaker()
    requested = requested_name.casefold()
    matches = [speaker for speaker in sc.all_speakers() if requested in speaker.name.casefold()]
    if len(matches) != 1:
        names = ", ".join(speaker.name for speaker in matches) or "none"
        raise RuntimeError(
            f"Speaker selector {requested_name!r} matched {len(matches)} devices: {names}"
        )
    return matches[0]


def main():
    args = parse_args()
    if args.sample_rate <= 0 or args.channels <= 0 or args.block_frames <= 0:
        raise ValueError("Sample rate, channels, and block size must be positive.")

    for module_dir in reversed(args.module_dir):
        sys.path.insert(0, str(pathlib.Path(module_dir).resolve()))

    try:
        import numpy as np
        import soundcard as sc
    except ModuleNotFoundError as error:
        raise RuntimeError(
            "Capture requires the Python packages numpy, soundcard, and cffi. "
            "Install them or pass --module-dir for a vendored package directory."
        ) from error

    output_path = pathlib.Path(args.output).resolve()
    stop_path = pathlib.Path(args.stop_file).resolve()
    ready_path = pathlib.Path(args.ready_file).resolve()
    metadata_path = pathlib.Path(args.metadata).resolve()
    for path in (output_path, stop_path, ready_path, metadata_path):
        if path.exists():
            raise FileExistsError(f"Refusing to reuse evidence path: {path}")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    speaker = select_speaker(sc, args.speaker_name)
    if speaker is None:
        raise RuntimeError("Windows has no selected output device for loopback capture.")
    microphone = sc.get_microphone(id=speaker.name, include_loopback=True)
    if microphone is None:
        raise RuntimeError(
            f"No WASAPI loopback endpoint matched the selected speaker: {speaker.name}"
        )

    total_frames = 0
    sum_squares = 0.0
    peak = 0.0
    started = None

    try:
        with wave.open(str(output_path), "wb") as wav_file:
            wav_file.setnchannels(args.channels)
            wav_file.setsampwidth(2)
            wav_file.setframerate(args.sample_rate)
            with microphone.recorder(
                samplerate=args.sample_rate,
                channels=args.channels,
                blocksize=args.block_frames,
            ) as recorder:
                started = time.time()
                write_json(
                    ready_path,
                    {
                        "speaker": speaker.name,
                        "loopback": microphone.name,
                        "sample_rate": args.sample_rate,
                        "channels": args.channels,
                        "started_epoch": started,
                    },
                )
                while not stop_path.exists():
                    samples = np.asarray(
                        recorder.record(numframes=args.block_frames), dtype=np.float32
                    )
                    if samples.ndim == 1:
                        samples = samples[:, np.newaxis]
                    if samples.shape[1] < args.channels:
                        repeats = args.channels - samples.shape[1]
                        samples = np.column_stack(
                            [samples] + [samples[:, -1:]] * repeats
                        )
                    elif samples.shape[1] > args.channels:
                        samples = samples[:, : args.channels]
                    samples = np.nan_to_num(
                        samples, nan=0.0, posinf=1.0, neginf=-1.0
                    )
                    samples = np.clip(samples, -1.0, 1.0)
                    peak = max(peak, float(np.max(np.abs(samples))))
                    sum_squares += float(
                        np.sum(np.square(samples, dtype=np.float64))
                    )
                    total_frames += samples.shape[0]
                    pcm = (samples * 32767.0).astype("<i2", copy=False)
                    wav_file.writeframesraw(pcm.tobytes(order="C"))
    finally:
        stopped = time.time()
        duration = total_frames / args.sample_rate if args.sample_rate else 0.0
        rms = (
            (sum_squares / (total_frames * args.channels)) ** 0.5
            if total_frames
            else 0.0
        )
        write_json(
            metadata_path,
            {
                "speaker": speaker.name,
                "loopback": microphone.name,
                "sample_rate": args.sample_rate,
                "channels": args.channels,
                "frames": total_frames,
                "duration_seconds": duration,
                "peak_linear": peak,
                "rms_linear": rms,
                "started_epoch": started,
                "stopped_epoch": stopped,
            },
        )


if __name__ == "__main__":
    main()
