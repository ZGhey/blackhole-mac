# Context

The words this codebase uses, and what they mean here. Written for whoever
reads the code next — including agents. When a term below has a definition,
use that word rather than a synonym; drift is what makes a codebase hard to
search.

## The picture

**Widget** — the floating `NSPanel` and everything it draws. Round, though the
window is square: the shader tapers its output to a soft disc and the controller
keeps the click region matched to it.

**Tracer** — the fragment shader, `BlackHole.metal`. Every pixel near the hole
integrates its own null geodesic; the shadow, lensing, photon ring, disk and
time dilation all fall out of that rather than being painted on.

**Lens** — what the hole bends. Either live screen content behind the widget
(`LensSource.screen`, via ScreenCaptureKit) or nothing at all
(`LensSource.stars`).

**Sky plane** — where the tracer paints a swallowed thing, so the geodesics can
bend it. A **sprite** occupies the one slot available: a dropped file (`Faller`)
or the pointer's image (`Proximity`). A drop wins.

**Morsel** — something droppable the hole can swallow: a file, a link, a scrap
of text, an image.

**Parking** — tearing the capture down and stopping the draw whenever nobody can
see the widget: hidden, displays asleep, session locked, or fully occluded.

## The tunables

**Tunable** — one named dial, e.g. `DISK_OUTER`. Its range, group, help text and
default are its **spec** (`ParamSpec`, all of them in `Specs`).

**Tunables** — the whole live set, as a value type. Foundation only; knows
nothing about SwiftUI.

**Params** — the app's `ObservableObject` shell over a `Tunables`. It persists
and publishes; it does not decide anything.

**Style** — a named sparse patch over the tunables ("Inferno", "Zen"). Built-in
styles name only what they care about so the rest compose; a style *you* saved
is stored whole, because a look you saved is the look you saw.

## The seam

**Uniforms** — the struct handed to the tracer each frame. Declared twice, in
Swift and in the shader, because shader source can never be shared. All-`Float`
so that declaration order *is* the memory layout — which is why a reorder is the
thing to fear, and why `make-check.sh` compares the two field for field.

**FrameInputs** — everything a frame contributes that is not a tunable: the
integrated `diskPhase`, the flare envelope, the resolved sprite, the step count
after Low Power has had its say. Already-resolved values only; it says what is
true this frame, never how it came to be.

**FrameUniforms** — the one function that fills a `Uniforms` in. Outside
`BlackHoleCore` the struct's members are read-only, so there cannot be a second.

**BlackHoleCore** — the target holding everything either side of the CPU→GPU
seam has to agree on. Its whole reason for existing is that the offscreen tools
can link it instead of retyping the uniform struct as a positional array.

## The measurements

Verification here is measurement: render offscreen and count. `make-check.sh` is
the suite, and every check in it corresponds to a bug that actually shipped.

**Fineness** — mean |∇²L| inside the disk as a percentage of its mean luma. The
number that catches the streak field **winding** itself below the pixel grid.

**Trip wire** — a threshold set well clear of the current value, not at it.
These checks are not golden images and are not meant to be tightened.
