# Stall-Speed Validation and Calibration

Use this procedure for dynamic stall cards. A stall is an event, not a steady-state average: separate configuration, setup convergence, maneuver entry, break detection, and post-break evidence.

## Build the matrix

- Match the POH aircraft variant, weight, CG convention, flap detent, gear, power, propeller, surface condition, and bank/load factor. Keep IAS, CAS, and KIAS/KTAS labels exact.
- To calibrate a whole envelope, test both CG endpoints and every flap detent before interpolating between them. Add representative intermediate and banked points; do not infer a high-bank correction from one wings-level card.
- Repeat accepted cards when break detection is discrete or run-to-run scatter is visible. Three accepted repeats per calibration anchor is a useful minimum; use more when the range remains large.
- If a required high-bank configuration cannot acquire a valid entry without changing the acceptance rules, report it as inconclusive. Never manufacture a datum from a setup failure.

## Initialize a physically consistent airborne state

Use a fresh `/flight` load for each card, pause immediately, wait for aircraft/plugin initialization, and rediscover custom datarefs. Initialization can overwrite station weights, so apply the desired station masses after that phase, settle, reread total mass and CG, and correct again before release.

Set attitude with `sim/flightmodel/position/q` using the quaternion formula in [xplane-web-api-testing.md](xplane-web-api-testing.md). Make the world velocity vector match heading and pitch, zero body rates, and preload controls and setup power before releasing position override or pause. Record angle of attack in the setup trace; otherwise an unintended velocity/attitude mismatch can masquerade as a model change.

## Require a sustained entry gate

Do not start the measured deceleration at the first one-frame crossing. Require the entry state continuously for a bounded interval, such as two seconds. A useful light-aircraft gate includes:

- normal load within about 0.05 g of the card target;
- vertical speed within about 400 fpm;
- pitch rate within about 2 degrees per second;
- bank within 3 degrees of target;
- sufficient IAS margin above the expected break;
- verified mass, CG, flap, and mod/readiness diagnostics.

These are starting tolerances, not substitutes for a POH procedure. A setup controller may use governed power and bank-aware pitch/power preload to acquire the gate. Remove that assistance when the card calls for throttle idle or a pilot-like free deceleration. Adjust setup energy or controller gains when banked entry fails; do not loosen the measurement acceptance limits.

Save the complete setup trace as `*.setup-failure.json` on failure. It is diagnostic evidence, never a performance result.

## Measure the break

- Follow the POH deceleration method when specified. For the recent SR20 campaign, accepted entries decelerated between 0.10 and 1.50 kt/s; treat that as a proven campaign range rather than a universal standard.
- Prefer a detector tied to the simulated aerodynamic break, such as a threshold count of stalled main-wing elements plus a load-factor drop or sink-rate onset. Preserve post-break samples so the trigger can be audited.
- Stall warning or a displayed AoA cue may lead or lag the native break. Record it, but do not silently substitute it for the chosen break definition.
- For the SR20 harness, the audited detector was the first sample with at least six stalled main-wing elements and either load factor below 0.88 or VVI below -500 fpm, falling back to the first six-element sample only if necessary. Revalidate these thresholds before using them on another aircraft or X-Plane version.
- Compute and retain pre-break bank over a defined window, entry deceleration rate, load factor, VVI, AoA, pitch rate, control positions, native stalled-element count, warning state, and mod force/activation diagnostics.

Reject a measured run for configuration mismatch, insufficient entry gate, deceleration outside the declared method, pre-break bank outside tolerance, ambiguous break evidence, or unexpected correction state. A plausible speed does not rescue a rejected maneuver.

## Tune without fitting one lucky run

Native element transitions are discrete and can move the reported break by roughly a sample or more between otherwise equivalent runs. Report every accepted value, the range, and the repeat mean.

When tuning a lift/normal-force coefficient:

1. Bracket the target with accepted runs at two coefficients.
2. Interpolate in squared speed when the correction follows dynamic pressure or load (`V^2`), not linearly in speed without justification.
3. Rerun the proposed coefficient several times and center the repeat distribution on the target.
4. If CG matters, expose and tune explicit forward and aft endpoint coefficients, interpolate using verified actual CG, and log the interpolation ratio and effective coefficient.
5. Treat runtime tuning datarefs as exploratory controls. Put final values into source defaults, bump the version, rebuild, and verify the compiled model with no overrides.

Do not assume one tuning dataref controls every CG endpoint. Read back the effective coefficient or force trace on each card so the harness proves which value the model actually used.

## Regression and evidence

After stall tuning, rerun at least one previously accepted cruise or climb card. A stall-only correction should show zero activation, zero applied force, and zero effective coefficient below its onset region unless the design explicitly says otherwise.

Retain:

- raw JSON trace for every measured run;
- setup-failure JSON for every failed entry;
- selected-card CSV and a machine-readable summary;
- POH target, observed values/range/mean/error, deceleration, bank, and rejection reason;
- harness, source, binary, ACF, and relevant airfoil SHA-256 hashes;
- runtime version and proof that the final run used compiled defaults;
- limitations such as break quantization, bank shortfall, or inconclusive configurations.

The final report must distinguish accepted measurements, rejected measured runs, and setup failures. Only accepted repeats support the calibrated result.