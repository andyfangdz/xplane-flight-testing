# Stall and Warning Modeling

Treat stall speed, break shape, local wing AoA, and aural-warning timing as related but distinct calibration surfaces. A matching stall speed does not prove that the wing stalls plausibly or that the warning leads by the correct margin.

## Preserve the host aerodynamics

- Preserve the original per-segment, Reynolds-number, and flap-dependent polar peak locations unless evidence identifies a specific bad polar. Do not warp every airfoil to one AoA merely to hit a speed target.
- Prefer a continuous, high-AoA-only lift or normal-force correction when the host is accurate in cruise and climb but misses the stall envelope. It should be zero below a documented onset and continuous through activation.
- Interpolate correction strength continuously by verified flap position and CG when those variables matter. Expose and log activation, applied force, and effective coefficient.
- After any stall correction, rerun cruise and climb cards and prove zero unintended activation there.

## Instrument local flow

Body AoA is not wing-element AoA. Incidence, downwash, flap geometry, and local flow can make area-weighted or maximum local AoA several degrees different from the aircraft-body value.

At a modest instrumentation rate such as 4 Hz, capture the main-wing element AoA, stalled flags, and element surface areas. Verify the flattened surface mapping for the exact aircraft and simulator version, ignore inactive near-zero-area elements, and compute area-weighted local AoA and stalled-area fraction. Use a break definition combining aerodynamic stalled area with load-factor loss or sink onset; tune its thresholds from audited traces rather than copying a raw element count from another aircraft.

## Schedule the native warning separately

Preserve the native X1000/FMOD warning presentation when possible. A plugin can schedule the writable `sim/aircraft/overflow/acf_stall_warn_alpha` control while leaving the native renderer and sound system responsible for annunciation and horn playback.

The scheduled value is an aircraft/body-AoA control threshold, not a claim about local wing-element stall AoA. One fixed threshold may not provide a consistent warning-speed lead across flap settings, weights, or CG. Calibrate endpoint thresholds for the required configurations, interpolate continuously between flap detents when appropriate, and log the effective schedule value.

Validate warning onset KIAS and warning-to-break lead separately from break KIAS at every required flap detent and CG endpoint. Capture synchronized sound evidence and confirm the horn in event-window spectral/RMS analysis; a warning-state dataref alone does not prove that audible warning reached the recording.
