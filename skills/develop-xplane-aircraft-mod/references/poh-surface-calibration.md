# POH surface calibration

## Preserve the table meaning

Record the aircraft variant, POH revision/page, weight, pressure altitude, temperature or ISA deviation, RPM, MAP/power setting, mixture technique, fuel flow, climb speed, and whether each speed is KIAS or KTAS. Keep row labels and units with the digitized values.

Interpolate only across dimensions supported by neighboring POH data. Report the actual sampled condition and the interpolation used. If X-Plane cannot realize a requested temperature aloft, reject the atmosphere card or compare to a clearly labeled interpolation at the realized atmosphere; do not silently score it against the requested condition.

## Separate three surfaces

Treat these as related but distinct:

1. **Command/indication surface:** power lever, RPM governor, MAP, mixture, fuel flow, and displayed percent power.
2. **Propulsive surface:** native shaft power, propeller efficiency, thrust, advance ratio, and any custom correction.
3. **Aircraft response:** stabilized KTAS, climb rate, acceleration, and low-speed behavior at the required mass/configuration.

Match RPM, MAP, and fuel flow before trusting a percent-power label. A native or custom display may use a formula different from the POH; expose both the POH-derived indication and physical-power diagnostics when they answer different questions.

## Build a wide matrix

Use the full available POH grid when feasible, not three convenient points. Include:

- low, middle, and high altitudes;
- cold, ISA, and hot conditions;
- economy, representative cruise, maximum cruise/WOT, and transition regions;
- both governor branches when RPM scheduling changes;
- low- and high-advance-ratio operation;
- climb and level-flight cards at their specified weights and speeds.

Use targeted probes to tune, then run a canonical regression set and retain holdout cells that were not used to choose coefficients. Stability gates matter as much as mean error: reject oscillating MAP/RPM or a controller that is still changing references during the official sample.

## Diagnose residual shape

- A nearly constant speed error across power/altitude suggests drag or a broadly applied useful-power error.
- Correct cruise with excessive climb suggests the low-advance-ratio propulsive regime needs separation, not a global power reduction.
- MAP errors concentrated at hot/high/WOT conditions suggest intake authority or limiter behavior.
- Correct engine indications with wrong aircraft response point downstream to propulsive efficiency, drag, or force ownership.
- A sign change with altitude or temperature requires a surface or regime boundary; do not hide it with one average multiplier.

Tune one cause at a time and rerun all anchors. Record rejected runs and different controller/setup procedures as non-comparable development history.

## Release acceptance

Require compiled/default values, no runtime tuning writes, acceptable errors across every declared regime, a clean unaffected-regime regression, stable controls/indications, and exact version/hash readback. Report worst-case and mean absolute errors rather than only the best card.
