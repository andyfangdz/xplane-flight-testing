# Native X1000 engine-page integration

## Prefer data injection to redraw

If an installed Laminar or third-party aircraft already provides the desired X1000 page family, first test whether its renderer reads standard engine datarefs that the custom engine model can publish. This preserves the native header, map, fonts, gauges, page navigation, softkeys, inset/full-page transitions, and future layout updates.

Do not claim native-widget reuse merely because a custom draw callback visually copies the page. Distinguish:

- **native renderer with injected data;**
- **native shell with a custom-drawn engine body;**
- **fully custom avionics page.**

Choose the narrowest viable design and state it accurately.

## Probe renderer assumptions in the simulator

ACF cylinder count, ICAO metadata, or invalid values may not change a private renderer's column layout. Test candidate controls in a duplicate aircraft and retain screenshots/state/logs for both full and compact pages. A private X1000 layer may render after SDK drawing callbacks, and a global suppression dataref may hide the whole EIS rather than individual widgets.

When the renderer has more native slots than the modeled engine, a documented slot mapping can preserve native rendering without inventing additional simulated cylinders. For example, a four-cylinder engine on a fixed six-slot page may publish `1,2,3,4,3,4`. Treat this as a host-specific presentation adapter: keep four independent thermal states and disclose the duplicated display positions.

## Override ownership

- Acquire only the simulator overrides needed for values the custom engine truly owns.
- Continue publishing ordinary native datarefs for values the host can render correctly.
- Do not suppress the native EIS when using native data injection.
- If a custom body is unavoidable, acquire the whole-page suppression deliberately and restore it on every disable/unload/mismatch path.
- Release EGT/CHT/oil/engine overrides before unregistering callbacks or datarefs.

The page model and the physical flight model may be separate plugins, but define their ownership boundary. An engine indication plugin should not silently change thrust unless that is part of its declared contract.

## Acceptance matrix

Verify at minimum:

- correct aircraft match, runtime version, and active state;
- the intended number of independent simulated cylinders and the complete native slot array;
- full ENGINE page and compact/inset page;
- page/softkey state transitions and native map/header behavior;
- RPM, MAP, percent power, fuel flow, oil, CHT, and EGT over a wide operating envelope;
- disabled, unloaded, mismatched-aircraft, replay, pause, and shutdown behavior;
- no remaining suppression/override after release;
- clean log with no deprecated-dataref, plugin-failure, threading, or crash markers.

Use visual evidence to validate layout and telemetry to validate values. Neither substitutes for the other.
