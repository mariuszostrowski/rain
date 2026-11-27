# Rain

*A rainy night, seen through a fogged-up window.*

Rain is a native macOS screen saver. Drops run down a misted window pane while the street behind it is a blur of headlights, sodium lamps and neon. It runs in real time in Metal. Nothing is pre-rendered and no video is looped, so it never shows the same thing twice.

## What you'll see

**Water that behaves like water.** Rain lands on the glass as tiny beads that grow and merge. Once a drop gets heavy enough it breaks loose and slides down in fits and starts, catching on the glass, drifting sideways and swallowing every drop in its path. Each drop is a tiny lens that shows an upside-down view of the street behind it.

**Trails that heal.** A sliding drop wipes a clear path through the condensation and sheds a line of droplets behind it. The droplets slowly dry out and the path fogs over again at its own pace, until you can't tell a drop ever passed.

**Condensation with character.** The mist is never even. It forms in patches, gets thicker near the bottom of the pane and is dotted with microscopic beads. Light from the street glows softly through it.

**A city that's alive.** The street behind the glass is fully out of focus, the way it would be through a real lens focused on the window:
- cars come and go, and their headlights and taillights are mirrored in the wet asphalt
- a traffic light cycles, and cars brake for the red
- apartment windows turn on and off through the night
- a neon sign stutters now and then

The bokeh is modelled on real optics. The discs are polygonal, with brighter rims and faint onion rings, have slight colour fringing and turn into cat's-eyes towards the edges of the frame.

**A different night every time.** Each run builds a new street with its own layout, horizon, lighting mood (warm sodium, cool LED, neon district or a mix) and amount of traffic.

## Requirements

- macOS 26 or later
- A Mac with Metal (any Apple Silicon Mac is perfect)

## Building & installing

1. Open `rain.xcodeproj` in Xcode and build (⌘B).
2. **Product → Show Build Folder in Finder**, then double-click `Rain.saver`.
3. Choose **Rain** in **System Settings → Screen Saver**.

When reinstalling a new build, first remove the old one (right-click it in System Settings → Delete), quit System Settings, and quit the `legacyScreenSaver` process if it's still running. macOS aggressively caches screen savers.

## Your own street

By default, the street is generated procedurally. To use your own photo, drop one or more images named `background*.jpg`, `.heic` or `.png` into the `rain/` folder (for example `background-tokyo.jpg`, `background-2.heic`) and rebuild. Rain picks one at random each time it starts, and procedural bokeh lights are layered on top. Dark, slightly blurred night shots work best.

## How it works

Every frame goes through five GPU passes:

| Pass | What it does |
| --- | --- |
| Scene | The street (photo or procedural) plus a few hundred instanced bokeh discs, in HDR |
| Blur | A heavy Gaussian blur of the scene, which is what you see through the fog |
| Water | Every drop is drawn into one combined height map, so touching drops merge smoothly |
| Condensation | A persistent fog and wetness map: water wipes it away, then it slowly re-forms |
| Composite | Refraction through each drop, fogged glass, micro-beads, filmic tone mapping, vignette and grain |

Drop physics (sticking, sliding, merging, shedding, evaporation) and the street's traffic run on the CPU.

| File | Contents |
| --- | --- |
| `RainView.swift` | Screen saver entry point and lifecycle |
| `RainRenderer.swift` | Metal pipeline |
| `DropSimulation.swift` | Water on glass |
| `BokehField.swift` | The street behind it |
| `Shaders.metal` | Everything you actually see |

## Known issues

- **Generic thumbnail.** Since macOS 26, System Settings no longer shows custom thumbnails for third-party screen savers (FB21094920). Rain ships `thumbnail.png` and `thumbnail@2x.png` anyway, in case Apple fixes it.
- **Taking a screenshot.** Any key press dismisses the screen saver. Run `sleep 10; screencapture ~/Desktop/rain.png` in Terminal and start the preview. Terminal needs the Screen Recording permission for this.
