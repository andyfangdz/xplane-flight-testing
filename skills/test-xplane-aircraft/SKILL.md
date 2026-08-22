---
name: test-xplane-aircraft
description: Run repeatable X-Plane 12 aircraft performance tests and compare stabilized in-simulator results with POH data. Use when benchmarking an aircraft, diagnosing excess or deficient performance, validating an ACF or plugin modification, building a flight-test matrix, or reporting book-versus-modeled climb, cruise, stall, takeoff, or landing performance.
---

# Test X-Plane Aircraft

Measure what the aircraft actually does in X-Plane. Treat configuration inspection as supporting evidence, never as a substitute for a controlled flown test.

## Workflow

### 1. Define the POH anchors

- Record the exact variant, POH revision, weight, altitude, temperature, mixture technique, RPM, manifold pressure or percent power, and whether speed is KIAS or KTAS.
- Test several anchors that expose different regimes: low- and high-altitude climb, economy cruise, high-power cruise, and the behavior the user observed.
- Interpolate to the actual sampled altitude or power. Label interpolations and nearby checks explicitly.
- If a custom display defines percent power differently, match POH RPM, manifold pressure, and fuel flow first. Report displayed percent separately.

### 2. Preserve the installation and run lineage

- Hash the source ACF and relevant runtime/plugin files before testing. Use a duplicate aircraft or reversible mod package.
- Record payload, station weights, tank fuel, weather, simulator/add-on versions, and any global plugin isolation.
- Use a dedicated X-Plane process and Web API port. Persist its exact PID, executable path, start time, and arguments; verify that identity before stopping only that process.
- For a clean-profile test, isolate non-stock global plugins and the complete Custom Scenery tree with an exact manifest and a prewritten recovery script. Read [references/clean-profile-testing.md](references/clean-profile-testing.md) before moving anything. Inventory reparse points and use atomic directory moves; never fall back to a recursive scenery move.
- Before isolation, capture protected installation state with `scripts/Protect-XPlaneInstallState.ps1`. Treat stock `Resources/default scenery`, `Global Scenery`, and vendor library links as read-only: never move, replace, redirect, or populate them for a test. An empty/missing stock tree or materialized vendor junction is a preflight failure, not a condition to work around.
- Keep test backups and quarantines outside `Aircraft`; X-Plane can scan an apparently valid aircraft folder that contains broken internal paths.
- Launch automated trials hidden with `--no_sound --no_joysticks --no_prefs --no_save_prefs` only when those restrictions fit the test. Omit `--no_sound` for aural evidence, and remember that `--no_prefs` can initialize individual sound groups at zero volume.
- A clean profile can remove the cause of a user-reported startup or control failure. Reproduce the exact reported path separately—including 2D versus VR, preferences, plugins, and scenery—and require the log to prove every suspected component actually loaded before treating that run as a valid control.
- Treat setup probes, rejected runs, and runs followed by crash callbacks as non-performance evidence. Retain them, but keep them separate from accepted results.
- A bad airborne load can leave sticky autopilot references, failures, or plugin state. Reset and read back state before every run. Use a fresh `/flight` load for each state-sensitive card, and restart the isolated process after an anomalous run rather than continuing blindly.
- Diagnose `Log.txt` before blaming the aircraft. For crashes, fatal dialogs, or main-thread enforcement failures, read [references/plugin-crash-triage.md](references/plugin-crash-triage.md). Isolate a global plugin only through a user-authorized, reversible, exact-file move, then restore it and verify the final log.

### 3. Build the test card

For every point, specify:

- POH target and acceptance tolerance;
- mass, CG treatment, and balanced fuel;
- ISA/static weather and zero wind unless the POH says otherwise;
- flight request, initial speed/heading, and load-safe pause timeout;
- aircraft readiness checks and state resets;
- commanded and required actual autopilot modes;
- convergence criteria, official stabilization period, sample count, and interval;
- automatic rejection rules.

Use 15 samples at 0.75-second intervals after 30-120 seconds of official stabilization as a strong default. Read [references/xplane-web-api-testing.md](references/xplane-web-api-testing.md) before changing an automated trial. For plugin-heavy aircraft or unreliable generic autopilot commands, also read [references/custom-aircraft-control.md](references/custom-aircraft-control.md).

For stall-speed validation or calibration, read [references/stall-calibration.md](references/stall-calibration.md). Dynamic cards need a sustained entry gate, an explicit break detector, repeated accepted runs, and separate setup-failure evidence; steady-state sampling defaults do not apply.

When the user requests a video or aural evidence, read [references/audio-video-evidence.md](references/audio-video-evidence.md). The flight trace remains the measurement authority; video and sound are synchronized supporting evidence and must pass their own acceptance checks.

### 4. Load safely and prove the achieved state

- Treat Web API socket readiness and flight-catalog readiness as different states. At the main menu, `/datarefs?limit=1` may work while the command catalog is empty.
- Map `sim/operation/pause_on` and `sim/time/paused` before `POST /flight` when available. If the main-menu catalog is empty, post the flight first, then discover the pause command immediately in a bounded loop.
- After the load request returns or its connection ends during reload, repeatedly command pause and verify `sim/time/paused == 1`. Do this before waiting for aircraft-specific datarefs; an airborne start can depart controlled flight during plugin initialization.
- While paused, wait for custom systems, refresh the command/dataref catalogs, set add-on-owned fuel and station mass, reset stale mode references, and read back critical values. A fresh load may overwrite station masses after the first write; settle, reread, and correct them again before release.
- For airborne dynamic initialization, write `sim/flightmodel/position/q`, not the read-only/ineffective Euler pitch dataref, and make the velocity vector consistent with heading and pitch. Zero angular rates and preload power and controls before releasing the override.
- Use finite command activations; 0.2 seconds is the proven default. Verify the generated executable harness contains that duration, not merely an outer wrapper.
- Distinguish command request, servo engagement, and achieved mode. `servos_on == 1` does not prove heading, ALT, VS, or FLC is active. Sample actual mode/status datarefs and readiness/power annunciators.
- If generic commands are ignored, discover the aircraft's native commands and status datarefs. A documented stable mode is acceptable when the intended mode is unavailable, but disclose the substitution.
- Engage FLC before setting its speed if engagement synchronizes the bug. If a rejected probe shows a consistent bug offset, adjust the command to obtain the POH **actual IAS** and record both values.
- Treat a mod's version/readiness and its regime-dependent correction state separately. An `active == 0` diagnostic can be correct where no correction should be applied; verify the expected state for the sampled regime rather than requiring one value everywhere.

Use [scripts/Invoke-XPlanePerfTrial.ps1](scripts/Invoke-XPlanePerfTrial.ps1) with a customized copy of [references/sample-trial.json](references/sample-trial.json). The runner implements immediate pause verification, finite command presses, catalog refresh, state readback, passive convergence, post-convergence mass correction, raw-result persistence, and generic rejection rules. For climb cards, also seed the adjustable mass dataref in `setupDatarefs` before convergence. Aircraft-specific active controllers still require a small adapter.

### 5. Converge, then stabilize

- Convergence and stabilization are separate phases. First acquire the requested altitude/speed/mode and require several consecutive in-tolerance checks.
- Rate-sensitive trials must start near the target mass. Seed the adjustable station or `m_fixed` estimate while paused before convergence, then let `massCorrection` fine-correct after convergence. Correcting only afterward can let a light aircraft climb hundreds of feet and bias the result.
- If native altitude capture is unavailable, an aircraft-specific bounded controller may adjust a verified pitch or speed reference during convergence. Tune it from rejected probes; do not copy another aircraft's gains.
- Stop changing control references once convergence passes. Only then begin the official stabilization clock.
- Require acquisition conditions for a sustained interval, not a single lucky sample. For dynamic tests, distinguish setup convergence, entry stabilization, and the measured maneuver; setup power or control assistance must be removed when the card requires an idle or pilot-like entry.
- Long convergence burns fuel. Correct adjustable station mass to the target after convergence and before official stabilization, then validate sampled total mass.
- Place the air start so the sample window—not merely convergence—falls near the POH altitude. If it misses materially, adjust the next start and rerun; use within-run altitude normalization only for a small disclosed offset.
- Abort on convergence timeout, mode loss, or implausible state. Do not let a controller drag a failed run into the sample window.

### 6. Reject bad runs and retain the evidence

Reject when any required condition is not continuously met, including:

- actual autopilot mode or servos;
- straight-flight bank limit, normally 3 degrees;
- fuel flow and tank availability;
- aircraft/plugin readiness or mod-active diagnostic;
- mass, controls, RPM, manifold pressure, fuel flow, or actual FLC IAS;
- IAS, altitude, or vertical-speed stability ranges;
- absence of post-run crash callbacks.

Persist raw JSON for every rejected sampling run and a diagnostic JSON for setup failures. Record ranges as well as means. Never promote a rejected probe merely because its average looks plausible.

For evidence runs, also reject a silent or truncated audio stream, failed sound-volume readback, corrupt video, or a recording that cannot be aligned to the accepted trace.

### 7. Compare, tune, and rerun

- Compare accepted averages at the actual sampled conditions; retain minimum, maximum, range, and raw observations.
- Show signed error as `(modeled - POH) / POH`.
- Tune one physical regime at a time, then rerun all anchors. A global power multiplier can fix cruise while worsening climb.
- When the measured event is discrete or quantized, use repeated accepted runs and report the distribution. Do not select a single favorable break as the calibrated result.
- After tuning through runtime overrides, put the final values into source defaults, rebuild, bump/verify the runtime version, and rerun with no tuning overrides. Regress at least one previously accepted unaffected regime.
- Keep development runs, but label different loading, controller, or setup procedures as non-comparable history.

### 8. Hand off and restore

Report simulator, aircraft, and mod versions; exact runtime formulas; POH rows and interpolation; accepted averages and stability ranges; rejected-run reasons; charts; limitations; final log review; and source/restoration hashes.

Restore every temporarily isolated plugin, scenery tree, or setting after stopping the test PID. Verify the manifest entry count, exact restored name sets, empty quarantine, critical hashes, protected-installation snapshot, and exact source ACF hash before reporting completion. If a graceful quit exceeds a bounded wait, verify the exact PID identity before forcing only that process.

## Safety and scope

Simulator tuning is not approved aircraft performance data and must not be used for real-world flight planning. If the user asks only for diagnosis or a report, do not modify the aircraft. If they ask for a mod, keep changes reversible and verify actual in-simulator behavior before calling it complete.
