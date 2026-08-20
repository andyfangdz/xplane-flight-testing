---
name: develop-xplane-aircraft-mod
description: Design, implement, and calibrate reversible aircraft-local X-Plane 12 modifications using ACF changes and SDK plugins. Use when building a custom flight or engine model, closing POH performance gaps, integrating modeled values with native avionics, or deciding between an ACF-only and plugin approach. For testing-only requests, use the X-Plane flight-test workflow instead.
---

# Develop X-Plane Aircraft Mod

Build the smallest aircraft-local model that closes demonstrated simulator gaps without hiding them behind commanded flight behavior. Treat controlled in-simulator measurements as the design feedback loop.

## Establish the contract

- Identify the exact host aircraft, simulator version, POH/model variant, target regimes, and behaviors that must remain native.
- Preserve licensing boundaries: reuse installed assets only inside a lawful derivative installation and do not redistribute proprietary aircraft content.
- Work in a duplicate aircraft package. Keep build tools, quarantines, and incomplete backups outside `Aircraft` so X-Plane cannot scan them as flyable variants.
- Define acceptance cards before implementation: performance anchors, display states, lifecycle behavior, and no-regression regimes.

## Choose the architecture from evidence

Start with ACF/airfoil/engine configuration when the required behavior is expressible there. Escalate to an aircraft-local SDK plugin only after a broad test matrix shows a repeatable residual that cannot be corrected without breaking another regime.

For the decision ladder, force-model boundaries, plugin scoping, and lifecycle rules, read [references/architecture-and-lifecycle.md](references/architecture-and-lifecycle.md).

Do not solve performance by commanding vertical speed, position, attitude, or autopilot modes. A custom model may alter physical configuration, engine state, forces, moments, or indications; the aircraft must still fly to the result.

## Calibrate surfaces, not anecdotes

- Digitize the applicable POH tables with units and conditions intact.
- Separate the engine indication/control surface from achieved aircraft performance. RPM, MAP, fuel flow, and displayed percent power can be correct while thrust, drag, or propeller efficiency remains wrong.
- Exercise altitude, temperature, power, RPM, mixture, airspeed, and weight broadly enough to expose coupled errors.
- Tune one physical regime at a time and rerun all previously accepted anchors.

For interpolation, realized-atmosphere handling, wide-envelope matrices, and regression strategy, read [references/poh-surface-calibration.md](references/poh-surface-calibration.md).

## Integrate avionics deliberately

Prefer publishing modeled values through standard simulator datarefs so the installed native avionics renderer remains responsible for layout, fonts, page navigation, and softkeys. Prove renderer behavior in the simulator; ACF metadata alone may not control private widget layouts.

For native X1000 engine-page reuse, cylinder-slot mapping, override ownership, and visual/lifecycle acceptance, read [references/native-x1000-integration.md](references/native-x1000-integration.md).

## Implementation invariants

- Match only the intended ACF and fail closed on another aircraft.
- Apply no force or indication override while paused, in replay, disabled, unloading, or mismatched.
- Keep XPLM and dataref access on X-Plane's main thread or a documented permitted callback.
- Expose version, match, enabled, active, commanded state, correction state, and limiting inputs as diagnostic datarefs.
- Make experimental tuning writable only when useful; place accepted values into source defaults, rebuild, and verify without runtime tuning overrides.
- Release every acquired override and clear every custom force contribution on disable, unload, and aircraft mismatch.
- Compile with warnings enabled as errors when practical and retain exact source/binary hashes with the test lineage.

## Verify and hand off

Use controlled X-Plane flight tests rather than configuration inspection alone. Verify the compiled/default model across the full target envelope, at least one unaffected regression regime, both enable/disable transitions, aircraft switching, replay/pause behavior, and a clean simulator shutdown log.

Report the architecture, exact formulas/tables, ACF changes, plugin ownership, accepted and rejected test cards, limitations, build instructions, and restoration hashes. Mark the result simulator-only and unsuitable for real-world flight planning.
