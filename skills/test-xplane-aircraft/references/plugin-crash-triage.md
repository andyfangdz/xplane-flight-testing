# X-Plane plugin crash triage

Use this when X-Plane crashes, shows a fatal/threading dialog, or fails only with a particular aircraft or test environment. Diagnose the first failing component before modifying the aircraft.

## Evidence order

1. Preserve `Log.txt`, the crash report/fatal dialog text, X-Plane version, exact launch arguments, loaded ACF path, and active plugin inventory.
2. Confirm whether the aircraft actually loaded. Missing-airfoil or missing-object paths can come from an accidentally scanned backup/quarantine beneath `Aircraft`; that is different from a plugin crash.
3. Search the final log section for crash callbacks, plugin signatures, main-thread/API violations, failed DLL loads, and the last successful aircraft-local initialization.
4. Reproduce once with the unchanged installation. Then run the same card with a clean profile containing only stock global plugins and the aircraft-local components it requires.
5. If the clean run passes, restore and add suspected global plugins back one at a time or in bounded groups. Force-feedback, telemetry, scripting, weather, and IPC plugins can alter controls, datarefs, timing, or thread behavior even when they are unrelated to the aircraft package.

## Threading failures

New X-Plane builds may enforce SDK main-thread restrictions that an older plugin previously violated without an immediate failure. Treat the log's named plugin or callback as the primary lead. Do not infer that an aircraft mod caused the crash merely because loading that aircraft exposed the callback.

When looking for an update, verify the current official release and its publication date/release notes. Do not claim that a newer build fixes the issue unless the vendor documents the relevant change or a controlled A/B test proves it.

For code under your control, keep XPLM/dataref access on X-Plane's main thread or a documented permitted callback. Worker threads may perform isolated computation or I/O only when the SDK contract allows it; hand simulator mutations back to the main thread.

## Acceptance and restoration

- A launch is not accepted merely because it reaches the cockpit. Run the same controlled test card and inspect the final log through clean shutdown.
- Retain failed runs as diagnostic evidence, not performance samples.
- Isolate or replace a third-party plugin only with user authorization and an exact, reversible move.
- Restore every plugin and scenery entry afterward and verify exact sets and hashes. If the suspect must remain disabled, report that as an explicit unresolved environment change rather than calling restoration complete.
