# Sound-enabled X-Plane evidence

Use this workflow when the user wants a recording of a maneuver, engine behavior, warning, or other audible/visual evidence. The accepted telemetry trace is still the quantitative result; the recording must be synchronized to it and independently validated.

## Sound readiness

Do not launch with `--no_sound`. If using `--no_prefs`, explicitly set and read back these datarefs after the aircraft is ready and before recording:

```text
sim/operation/sound/sound_on
sim/operation/sound/master_volume_ratio
sim/operation/sound/engine_volume_ratio
sim/operation/sound/prop_volume_ratio
sim/operation/sound/interior_volume_ratio
sim/operation/sound/exterior_volume_ratio
sim/operation/sound/warning_volume_ratio
```

`--no_prefs` can leave the individual groups at zero even while `sound_on == 1`. Require the enabled flag and every required group to read back near the commanded value. Preserve those readbacks with the flight result.

Check `Log.txt` for the FMOD output driver. The WASAPI loopback endpoint must correspond to the Windows device receiving X-Plane audio; a healthy recorder attached to another device is still silent evidence.

## Recording sequence

1. Converge the setup and pass every flight-card gate before starting evidence capture.
2. Start [Capture-WasapiLoopback.py](../scripts/Capture-WasapiLoopback.py) and wait for its ready JSON. Record its `started_epoch`, device, sample rate, and channel count.
3. Select the intended X-Plane view, start X-Plane's movie recorder, and record the movie start time or retain the new AVI's creation time.
4. Execute the maneuver while collecting the normal telemetry trace.
5. Stop X-Plane's movie recorder first, then create the audio stop sentinel and wait for clean recorder exit.
6. Reject the evidence unless the flight card passed, the audio metadata is non-silent and long enough, and the movie fully decodes.

The native X-Plane AVI commonly contains MJPEG video without audio. Use [Finalize-XPlaneEvidence.ps1](../scripts/Finalize-XPlaneEvidence.ps1) to align the loopback WAV from the two start timestamps, encode H.264/AAC, perform a full decode pass, and measure output volume.

Example capture command:

```powershell
py -3 <skill>/scripts/Capture-WasapiLoopback.py `
  --module-dir <directory-containing-soundcard-and-numpy> `
  --output <run>/audio.wav `
  --ready-file <run>/audio.ready.json `
  --stop-file <run>/audio.stop `
  --metadata <run>/audio.metadata.json
```

Example finalization command:

```powershell
& <skill>/scripts/Finalize-XPlaneEvidence.ps1 `
  -VideoPath <X-Plane-AVI> `
  -AudioPath <run>/audio.wav `
  -AudioMetadataPath <run>/audio.metadata.json `
  -FfmpegPath <ffmpeg.exe> `
  -OutputPath <run>/accepted-evidence.mp4 `
  -ResultPath <run>/accepted-evidence.verification.json
```

## Acceptance

Reject and repeat when any of these is true:

- a required sound dataref did not read back enabled;
- WAV peak or RMS is zero/near-zero, the stream is materially shorter than the movie, or capture exited abnormally;
- the audio endpoint differs from the device X-Plane actually used;
- the final MP4 fails a complete decode, has no video or audio stream, or reports effectively silent output;
- frames around the measured event do not show the expected pre-event, event, and recovery phases;
- timestamps cannot place the measured telemetry event within the recording.

Extract frames before, at, and after the trace event and inspect them. For stalls, the warning horn is supporting evidence only; use the flight-model break detector and trace as the measurement authority.
