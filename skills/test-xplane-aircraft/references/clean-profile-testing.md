# Clean-profile X-Plane testing

Use this procedure when global plugins, force-feedback software, preferences, or scenery could contaminate a performance test. An interrupted test must not leave the user's installation altered.

## Before moving anything

1. Stop X-Plane and verify that no X-Plane process remains.
2. Create a task-owned quarantine under `Output/performance-tests/<run>/isolation-clean-profile`. Never park quarantined or incomplete aircraft beneath `Aircraft`; X-Plane may scan them and follow broken internal paths.
3. Capture the protected installation state before isolation:

   ```powershell
   & <skill>/scripts/Protect-XPlaneInstallState.ps1 -Mode Capture `
     -XPlaneRoot <x-plane-root> `
     -SnapshotPath <run>/isolation-clean-profile/protected-install-state.json
   ```

   This is a hard preflight gate. It rejects an empty/missing stock `Resources/default scenery`, an unresolved carrier-library object, and a materialized or misdirected simHeaven `XP12_libs` entry.
4. Inventory every top-level entry in `Resources/plugins`. A normal stock allowlist is `PluginAdmin`, the SDK DLL/framework, `Commands.txt`, and `DataRefs.txt`; verify against the installed version instead of assuming.
5. Record each source and quarantine path, entry type, attributes, link type/target when applicable, and size. Hash critical files such as XPUIPC and TelemFFB before isolation.
6. Record the resolved `Custom Scenery` path and its complete top-level inventory. Also inventory every descendant reparse point by relative path, link type, and target without following it. Broken-target junctions are valid inventory entries, not errors to repair.
7. Write the recovery script before isolation. It must refuse to run while X-Plane is active, use exact literal paths, fail on destination collisions, preserve reparse points without traversal, and write a restoration status record.
8. Give the empty test scenery directory a unique marker file and token recorded in the manifest. X-Plane normally creates a 55-byte `scenery_packs.ini` there containing only its header and `SCENERY_PACK *GLOBAL_AIRPORTS*`. Restoration may preserve that exact generated file as test evidence before validating the marker-only placeholder. Any different or additional entry is a collision: preserve both scenery trees and stop.

`Resources/default scenery`, `Global Scenery`, and vendor library links are protected, read-only installation state during a clean-profile test. Do not move, replace, junction, copy, populate, or temporarily redirect them. Do not use an ad hoc compatibility library to mask a missing stock export. If the guard fails, stop testing and handle installation repair as a separate, user-authorized task.

On Windows, use native PowerShell for the entire move and recovery workflow. Do not pass computed paths between shells.

## Isolation

- Move every manifested non-stock plugin entry into quarantine; never delete it. This includes TelemFFB, XPUIPC, FlyWithLua, and other force-feedback or telemetry integrations.
- Atomically rename the whole `Custom Scenery` directory with `[IO.Directory]::Move` to a same-volume task quarantine, then create the marked empty placeholder at the original path. Do not use `Move-Item` for the scenery tree: it can traverse a junction and partially split the tree.
- Re-inventory both locations and abort if any unmanifested non-stock plugin remains.
- Do not isolate aircraft-local components that the aircraft requires unless that component is itself the test target.
- Never use a recursive copy as a substitute for the atomic scenery rename. It can dereference a vendor junction, duplicate many gigabytes into the package, and leave the stock source empty or unavailable.

If the atomic scenery rename fails, stop. Do not substitute a recursive copy/move or continue with a partially isolated profile.

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
3. Run the prewritten recovery script. [scripts/Restore-XPlaneCleanProfile.ps1](../scripts/Restore-XPlaneCleanProfile.ps1) implements the schema and atomic behavior described below, including exact recognition and preservation of X-Plane's clean-profile `scenery_packs.ini`.
4. Verify that every plugin entry is back and the plugin quarantine is empty.
5. Compare the restored plugin and scenery name sets with the manifest and report counts, missing entries, and extra entries; equal counts alone are insufficient.
6. Verify that the original scenery directory is restored, the temporary placeholder is gone, and the parked directory no longer exists. Verify every recorded reparse point still has the same link type and target.
7. Recompute critical environment hashes and compare them with the pre-test manifest. Treat intentional aircraft/mod changes as a separate expected-hash set.
8. Verify the protected installation snapshot with `Protect-XPlaneInstallState.ps1 -Mode Verify`. Restoration is incomplete if path type, link target, top-level inventory, or protected hashes differ.
9. Write the UTC restoration time and verification results to the run record.

After the tracked process exits, a plugin DLL may remain transiently locked. Verify that no matching X-Plane process remains, wait briefly, and retry a bounded number of times before diagnosing a build or restore failure.

Do not bless an unexplained mismatch by rewriting the pre-test manifest. When
the test intentionally deploys an accepted aircraft source or binary, retain
the original hash and record the reviewed replacement hash as a separate
expected change. Environment files, global plugins, scenery, and protected
installation state must still match their original snapshot.

## Atomic recovery states

Use a manifest with `schema_version: 5` and these fields:

- `xplane_root`, `plugin_root`, `stock_allowlist`, and `plugin_entries[]` with `name`, `original_path`, and `quarantined_path`;
- `scenery.original_path`, `quarantined_path`, `test_placeholder_park_path`, `placeholder_marker_name`, `placeholder_token`, `top_level_entries[]`, and `reparse_points[]`;
- `critical_hashes[]` with `path` and `sha256` for environment files that must remain unchanged.
- `protected_installation_snapshot` containing the absolute path to the pre-isolation snapshot under the isolation root.

The recovery script retains schema 4 compatibility for old quarantines. New tests must write schema 5 so restoration cannot pass while stock/default scenery or vendor-link topology has changed.

Recovery must handle only unambiguous states:

- **Staged original + marked live placeholder:** if the placeholder also contains the exact X-Plane-generated clean-profile `scenery_packs.ini`, move that file to the isolation root as evidence; atomically park the now marker-only placeholder, then atomically rename the staged original back.
- **Staged original + no live directory:** atomically rename the staged original back.
- **No staged original + complete live inventory:** treat the directory rename as already completed and continue the audit.
- **Staged original + non-placeholder live content:** stop and preserve both sides. This is a split/collision state requiring an explicit union audit; never merge recursively or overwrite a reparse point.

If the original atomic rename fails after parking the placeholder, restore the marked placeholder atomically and leave the original staging tree untouched. Never let a convenience fallback turn a recoverable failure into a partial merge.

Run the reusable recovery script with:

```powershell
& <skill>/scripts/Restore-XPlaneCleanProfile.ps1 -ManifestPath <run>/isolation-clean-profile/isolation-manifest.json
```

Do not mark the run complete while recovery is pending or any inventory/hash differs. Preserve the quarantine and report the exact mismatch rather than guessing.
