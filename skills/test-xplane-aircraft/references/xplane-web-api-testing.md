# X-Plane 12 Web API Performance Testing

## Load-safe session pattern

1. Launch a dedicated hidden X-Plane process with `--web_server_port=<unused-port>` and record its PID. For clean automation, prefer `--no_sound --no_joysticks --no_prefs --no_save_prefs`; quote a `--load_acf` path containing spaces as one argument.
2. Poll `http://127.0.0.1:<port>/api/v3/datarefs?limit=1` until ready.
3. Try to map `sim/operation/pause_on` and `sim/time/paused`, but do not treat an empty main-menu command catalog as a crash. API socket readiness does not guarantee a flight catalog.
4. `POST /api/v3/flight`. `--load_acf` alone may leave X-Plane in a ready/menu state, and a preflight 404 is not necessarily a hang. X-Plane may end the HTTP response while reloading; suppress only that recognized connection-ending case.
5. Discover the pause command if it was unavailable, command pause in a bounded retry loop, and read back `sim/time/paused == 1`. Do not wait for custom aircraft datarefs first.
6. Wait for plugin initialization while paused, then refresh both catalogs. Numeric IDs and aircraft-specific availability must be treated as post-load state; never reuse custom-dataref IDs across a flight reload without rediscovery.
7. Reset stale references and configure add-on-owned mass/fuel. A load can rewrite station masses after an early write, so settle, reread, correct, and verify both total mass and CG before release.
8. Run any paused readiness checks, unpause, issue finite-duration mode commands, apply targets that must follow mode engagement, and verify achieved modes.
9. For climb or acceleration tests, seed target mass before convergence. Converge, fine-correct mass, begin the official stabilization clock, sample, validate, and only then average.
10. Save raw evidence, inspect the final log for crash callbacks, stop the exact PID, restore isolated plugins and scenery, and verify manifest counts, quarantine emptiness, hashes, and settings.

Use a full `/flight` load for every state-sensitive card. Reusing an airborne state can preserve failures, synchronized references, plugin state, or fuel/payload ownership from the preceding maneuver.

The reusable runner follows this state machine. A custom controller may wrap it, but must preserve the pause, readback, convergence, stabilization, and rejection boundaries.

For full plugin/scenery isolation and recovery invariants, read [clean-profile-testing.md](clean-profile-testing.md).

## API endpoints

- `POST /api/v3/flight`
- `GET /api/v3/datarefs?limit=30000`
- `GET /api/v3/commands?limit=20000`
- `GET /api/v3/datarefs/{id}/value`
- `PATCH /api/v3/datarefs/{id}/value`
- `POST /api/v3/command/{id}/activate`

Set `NO_PROXY=localhost,127.0.0.1` so a system proxy does not intercept local traffic.

## Runner configuration

`Invoke-XPlanePerfTrial.ps1` supports these reusable controls:

| Field | Purpose |
|---|---|
| `flightRequest` | Complete `/flight` payload. |
| `immediatePauseTimeoutSeconds` | Maximum time to prove pause after load. |
| `pluginInitSeconds` | Time held paused before post-load catalog discovery. |
| `discoveryTimeoutSeconds` | Catalog retry window for required custom names. |
| `resetDatarefs` | Sticky references to set and verify before setup. |
| `setupDatarefs` / `pausedCommands` | Configuration applied while paused. |
| `pausedReadiness` | Conditions that must become true before unpause. |
| `afterSetupCommands` | Finite command activations after unpause. |
| `afterCommandDatarefs` | Targets applied after mode engagement, such as FLC IAS. |
| `postCommandState` | Actual mode/status conditions that must be acquired. |
| `convergence` | Passive conditions required consecutively before stabilization. |
| `massCorrection` | Iterative adjustment of one station to restore target total mass. |
| `reject` | Sample-window acceptance rules. |

Dataref settings may include `readbackTolerance`. State/convergence conditions accept `target` plus `tolerance`, `minimum`, and/or `maximum`. `consecutiveChecks` prevents a single lucky observation from passing acquisition.

The generic runner deliberately does not synthesize control inputs during convergence. If the aircraft cannot acquire a stable condition using its native modes, create an aircraft-specific adapter following [custom-aircraft-control.md](custom-aircraft-control.md).

## Minimum evidence set

| Quantity | Typical dataref or treatment |
|---|---|
| IAS | `sim/flightmodel/position/indicated_airspeed` (knots in the tested API) |
| TAS | `sim/flightmodel/position/true_airspeed` (m/s; multiply by 1.94384449) |
| VVI | `sim/flightmodel/position/vh_ind_fpm` |
| Altitude | `sim/flightmodel/position/elevation` (m; multiply by 3.28083990) |
| Bank | `sim/flightmodel/position/phi` |
| RPM | `sim/flightmodel/engine/ENGN_tacrad` (rad/s; divide by 0.1047197551) |
| Manifold pressure | `sim/flightmodel/engine/ENGN_MPR` |
| Mass | `sim/flightmodel/weight/m_total` |
| AP servos | `sim/cockpit2/autopilot/servos_on` |
| AP modes | Aircraft/native mode status and annunciator datarefs |
| Fuel flow | Aircraft-owned value where available |
| Mod state | Aircraft-local active/factor diagnostic where available |

Discover aircraft-owned fuel, percent-power, station-weight, and mode datarefs rather than assuming generic values own the state.

For airborne dynamic initialization, use the writable quaternion `sim/flightmodel/position/q`; writing an Euler attitude indicator such as `theta` may not change the simulated attitude. Given heading `psi`, pitch `theta`, and bank `phi` in radians, with half-angle sine/cosine terms, use:

```text
q0 = cpsi*ctheta*cphi + spsi*stheta*sphi
q1 = cpsi*ctheta*sphi - spsi*stheta*cphi
q2 = cpsi*stheta*cphi + spsi*ctheta*sphi
q3 = -cpsi*stheta*sphi + spsi*ctheta*cphi
```

Make velocity agree with that attitude: `horizontal = V*cos(pitch)`, `vx = horizontal*sin(heading)`, `vy = V*sin(pitch)`, and `vz = -horizontal*cos(heading)`. Zero body angular rates and include measured angle of attack in the setup trace so a hidden initialization error is visible.

## Stability and acceptance

- Cruise: 60-120 seconds of official stabilization after convergence.
- Climb: 30-45 seconds after acquiring actual IAS and a clean, stable climb.
- Sample window: 15 observations, 750 ms apart.
- Straight-flight bank: 3 degrees absolute maximum unless the card says otherwise.
- Validate means **and** ranges. A plausible mean is not credible if IAS, altitude, or VVI is trending.
- Validate actual sampled mass after long convergence/stabilization.
- On rate-sensitive trials, seed the adjustable mass in `setupDatarefs` before convergence; `massCorrection` then fine-corrects after convergence. A correction performed only after convergence does not undo altitude gained while too light.
- Tune the air-start elevation so samples remain close to the POH altitude. Prefer a rerun over extrapolating a distant sample.
- Keep commanded FLC bug distinct from actual sampled IAS.

## POH comparison and reproducibility

Interpolate at actual mean altitude or power. Keep IAS and TAS distinct. Treat custom displayed percent power as model-specific unless its formula matches the POH; match RPM, manifold pressure, and fuel flow first.

Retain the config, raw accepted and rejected JSON, setup-failure diagnostics, controller/adapter source, source hashes, simulator/add-on versions, relevant `Log.txt`, POH page/table, interpolation math, and a summary that identifies the exact accepted files.