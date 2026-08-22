# Architecture and lifecycle

## Modification ladder

Use the least invasive layer that can represent the required behavior:

1. **ACF and airfoil configuration:** dimensions, mass properties, control geometry, engine type/power, propeller, inlet recovery, drag, and stability derivatives.
2. **Aircraft-local indication/control adapter:** translate native engine state into the target aircraft's controls or indications while leaving forces with X-Plane.
3. **Aircraft-local physical correction:** add a bounded force, moment, or engine/propulsive correction for a demonstrated regime-dependent residual.
4. **Full custom ownership:** only when the host model cannot be made internally consistent through narrower layers. Define exactly which native subsystems are overridden and how ownership is released.

Do not add a plugin merely because one offers easier tuning. First test an ACF-only candidate across cruise, climb, low-speed/stall, and any behavior the user reported. Escalation is justified when the same physical knob cannot close the residuals without a material regression elsewhere.

## Physical corrections

State the correction in physical terms. For a power residual, a useful starting relationship is force proportional to useful-power difference divided by true airspeed. Protect the low-speed singularity, clamp the result, choose the correct aircraft/body axis and sign, and taper the correction outside the calibrated advance-ratio/power regime.

Check for double counting. If X-Plane already changes thrust with density, RPM, propeller efficiency, or mixture, a second correction using the same factor can fit one card while becoming nonphysical elsewhere. Expose native thrust/efficiency and every correction term as diagnostics.

A flight-model plugin must not command vertical speed or position to manufacture a POH result. It may add a physical force or alter a subsystem it explicitly owns; the resulting climb, cruise, and acceleration must emerge from the simulation.

## Aircraft-local plugin boundary

- Install under the target aircraft's `plugins` directory, not the global plugin directory.
- Match a stable aircraft identity such as the exact loaded ACF path/name plus intended metadata. An ICAO code alone may collide with unrelated aircraft.
- Register callbacks and datarefs once; keep `enabled`, `aircraft_match`, `active`, and version diagnostics distinct.
- Return zero correction until all required datarefs are available and the aircraft is matched.
- Use before/after-flight-model callbacks intentionally and document why the selected phase is correct.
- Keep SDK/dataref operations on X-Plane's main thread. Worker threads may do isolated computation or I/O only within the SDK contract.

Treat writable bindings in Lua and test harnesses as subsystem ownership too.
Do not leave an occasionally written position, attitude, throttle, or autopilot
dataref continuously writable for convenient reads; bind it read-only and issue
one-shot writes only during a bounded requested operation. If simulator state
changes and then snaps back, inventory every writer before modifying the native
system or adding an adapter.

## Fail-closed lifecycle

The plugin must return the host aircraft to native behavior when any of these becomes true:

- plugin disabled or stopped;
- another ACF loads;
- simulation paused or replaying;
- required readiness/datarefs become invalid;
- an override cannot be acquired safely.

On every exit path, set custom forces/moments to zero and release indication or engine overrides. Test live disable/re-enable, aircraft mismatch, aircraft switching, replay, pause, and clean shutdown. Preserve a log proving no crash callback, threading violation, or leaked override.

## Development to release

Writable tuning datarefs are exploratory controls, not the delivered configuration. After calibration:

1. write accepted values into source defaults;
2. rebuild with warnings treated as errors when practical;
3. bump and read back the runtime version;
4. rerun with no tuning writes;
5. compare source and binary hashes with the intended release set;
6. regress previously accepted regimes that should be unaffected.
