# Clean-profile X-Plane testing

Use this procedure when global plugins, force-feedback software, preferences, or scenery could contaminate a performance test. An interrupted test must not leave the user's installation altered.

## Before moving anything

1. Stop X-Plane and verify that no X-Plane process remains.
2. Create a task-owned quarantine under `Output/performance-tests/<run>/isolation-clean-profile`. Never park quarantined or incomplete aircraft beneath `Aircraft`; X-Plane may scan them and follow broken internal paths.
3. Inventory every top-level entry in `Resources/plugins`. A normal stock allowlist is `PluginAdmin`, the SDK DLL/framework, `Commands.txt`, and `DataRefs.txt`; verify against the installed version instead of assuming.
4. Record each source and quarantine path, entry type, and size. Hash critical files such as XPUIPC and TelemFFB before isolation.
5. Record the resolved `Custom Scenery` path and its complete top-level inventory, including names and entry types.
6. Write the recovery script before isolation. It must refuse to run while X-Plane is active, use exact literal paths, fail on destination collisions, and write a restoration status record.

On Windows, use native PowerShell for the entire move and recovery workflow. Do not pass computed paths between shells.

## Isolation

- Move every manifested non-stock plugin entry into quarantine; never delete it. This includes TelemFFB, XPUIPC, FlyWithLua, and other force-feedback or telemetry integrations.
- Move the whole `Custom Scenery` directory intact and create a fresh empty placeholder at the original path.
- Re-inventory both locations and abort if any unmanifested non-stock plugin remains.
- Do not isolate aircraft-local components that the aircraft requires unless that component is itself the test target.

## Launch

Recommended clean flags:

```text
--web_server_port=<unused> --no_sound --no_joysticks --no_prefs --no_save_prefs --load_acf="Aircraft/.../Aircraft.acf"
```

Launch hidden, quote the aircraft path, and persist the exact PID, executable path, start time, arguments, API port, and expected ACF. Confirm the loaded aircraft in `Log.txt`.

The web API socket can bind before the flight catalog is ready. Treat a successful dataref request only as socket readiness. `--load_acf` can still leave X-Plane in a ready/menu state; a preflight 404 or missing aircraft dataref is not by itself a hang. POST the flight, then discover and set the pause dataref if necessary, and verify the loaded aircraft and test state before sampling.

## Recovery and verification

1. Request a graceful, bounded X-Plane shutdown.
2. Before a forced stop, verify that the recorded PID still identifies the launched X-Plane process.
3. Run the prewritten recovery script.
4. Verify that every plugin entry is back and the plugin quarantine is empty.
5. Compare the restored plugin and scenery name sets with the manifest and report counts, missing entries, and extra entries; equal counts alone are insufficient.
6. Verify that the original scenery directory is restored, the temporary placeholder is gone, and the parked directory no longer exists.
7. Recompute critical environment hashes and compare them with the pre-test manifest. Treat intentional aircraft/mod changes as a separate expected-hash set.
8. Write the UTC restoration time and verification results to the run record.

After the tracked process exits, a plugin DLL may remain transiently locked. Verify that no matching X-Plane process remains, wait briefly, and retry a bounded number of times before diagnosing a build or restore failure.

Do not mark the run complete while recovery is pending or any inventory/hash differs. Preserve the quarantine and report the exact mismatch rather than guessing.