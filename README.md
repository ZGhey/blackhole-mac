# Black Hole — a floating widget for macOS

The renderer from [`blackhole.glsl`](../blackhole.glsl), lifted out of Ghostty
into a native macOS app: Metal, one fullscreen triangle, one fragment shader.
Same physics, same numbers — every pixel near the hole integrates its own null
geodesic through the Schwarzschild metric, and the shadow, lensing, photon ring,
disk images and time dilation all fall out of that integration rather than being
painted on.

It floats above your windows and **bends the live screen behind it**. Your
editor, your browser, your Finder icons genuinely warp around the horizon.

```sh
./macapp/make-signing-cert.sh     # once — see "Permissions" below
./macapp/make-app.sh && open "macapp/dist/Black Hole.app"
```

Requires macOS 13+. There is no Dock icon and no main window: the app lives in
the menu bar (⚫).

## Using it

Everything is in the menu-bar menu.

- **Size** — Small, Medium, Large. Dragging anywhere on the disc moves it, and
  Position ▸ Snap puts it flush against an edge, which dragging by hand cannot
  quite reach.
- **Style** — Inferno, Gargantua, M87\* donut, Face-on ember, Quasar, Blazar,
  Pure lens, Zen. These disagree wildly about how wide the accretion disk is
  (7 r_s for Gargantua, 16 for Blazar), so the hole is scaled down automatically
  until the bright part fits the frame. Every style fills the same widget
  without being clipped.
- **Lens** — *Live screen* (the default) or *Stars only*, which needs no
  permission and leaves everything but the hole transparent. **Pulse with
  audio** drives the disk's brightness and rotation from system audio; it rides
  the same capture stream, so it needs the live-screen lens.
- **Position** — *Stay put*, *Follow cursor*, or *Snap to active window*
  (Accessibility permission). Follow-cursor is decoration only: it sits under
  the pointer, so it stays click-through and cannot take drops.
- **Dropped things** — drop a file, a selection of text, a link or an image on
  the hole and watch it be eaten (below). **The default is the animation only
  and touches nothing**; moving files to the Trash is opt-in, and only ever
  applies to things that exist on disk.
- **Swallow the pointer** — put the cursor inside and its image is dragged
  toward the middle, stretched and reddened until it goes out. The real pointer
  is never touched; move back out and the image catches up.
- **Launch at login** — registers via `SMAppService`. Needs the signed bundle,
  so it does nothing under `swift run`.
- **Advanced…** — a slider for every tunable, if the styles are not enough.
  Anything you tune can be kept: Style ▸ **Save current as…**. Custom looks are
  stored whole rather than as a sparse patch, because a look you saved is the
  look you saw, and inheriting stray values from whatever was loaded before
  would not reproduce it.
- **⌥⌘B** hides and shows it. Carbon's `RegisterEventHotKey`, deliberately not
  an `NSEvent` monitor — those need the Accessibility permission for key
  events, and a widget you want to hide should not demand the right to watch
  everything you type. Hiding fades it out and leaves the capture stream and
  timers alone, so coming back is instant.
- Positions are remembered **per display**. A widget parked in the corner of a
  laptop screen has no business landing in the middle of a 5K one when you
  dock, and the reverse leaves it off the edge entirely.

## One dial for the proportions

The composition always fills the window, so the window *is* the visible disc —
there is no dead border to catch on the edge of a screen. That leaves exactly
one thing to decide: **`HALO`**, how much lensed background rings the disk, as a
multiple of the disk's own radius. 1.0 is the warp hugging it exactly.

Two earlier dials for this are gone, and it is worth saying why rather than
quietly dropping them: they cancelled out. Working the algebra through,
`rh = (room·B_CRIT/lit)·MAX/(halo·room)` — `room` divides out, and the same is
true of the hole's own scale. All they ever changed was how much of the window
the composition declined to use, which is to say they existed to create the dead
border. Size belongs to the window; proportion belongs to `HALO`.

The extent being fitted is what actually *glows*, not the disk's nominal outer
edge: emission has faded out by `rout*0.70`, so measuring against `DISK_OUTER`
hands roughly a third of the frame to disk that emits nothing.

## The window is square; nothing else is

An AppKit window is a rectangle, and its click region is all-or-nothing. Neither
is true of what you see:

- The shader tapers its output **radially**, so the warp is gone before the
  border and the silhouette is a **soft-edged disc**. Without that the frame
  slices through the halo — which runs several times wider than the widget — and
  the clipped band is an opaque, capture-stale copy of your screen that lags
  visibly over anything moving underneath.
- Alpha rides the same taper, so the captured copy **crossfades** into the real
  screen instead of ending on a visible rim.
- The **click region follows the disc**: the corners are not there, and a click
  in them lands on whatever is underneath. The controller polls the pointer and
  flips `ignoresMouseEvents` to match.

Everything the hole does not deflect comes out at alpha 0, so the untouched
parts of the widget are not a copy of the screen — they *are* the screen.

## Permissions

**Screen Recording** is needed for the live-screen lens. Grant it when macOS
asks.

It is worth knowing why the build signs itself. macOS keys a TCC grant to the
app's *designated requirement*, and an ad-hoc signature produces one built from
the binary's own hash:

```
designated => cdhash H"ebe3f233a58da2216530360c39fedcd7e4dcb103"
```

Every rebuild changes that hash, so every rebuild silently revokes the
permission. `make-signing-cert.sh` creates a self-signed code-signing identity
once, and `make-app.sh` finds it from then on, which anchors the requirement to
the certificate instead:

```
designated => identifier "dev.s13k.blackhole-app" and certificate leaf = H"bf84f9…"
```

Now the grant survives rebuilds. To undo it all,
`security delete-certificate -c "Black Hole Dev"`.

If a permission gets stuck anyway, **Ask for Screen Recording again** in the
menu runs `tccutil reset ScreenCapture` so macOS prompts fresh. A denied or
failed capture retries every 5 s and reports once rather than spinning — an
immediate retry loop hammers TCC and floods the log.

**Accessibility** is needed only for *Snap to active window*.

## What moves, and why it had to be made to

The lensed halo is a *static mapping* of whatever is behind the widget. Point it
at a still screen and, left alone, not one pixel outside the disk changes —
measured at 0.25/255 per second against 7.0 inside it. The halo has no motion of
its own; it only moves when the warp field does.

So the hole drifts. `DRIFT` puts it back on the Lissajous the GLSL used to walk
it across a whole terminal — two incommensurate sines per axis, so the path
never repeats — just small enough that a dropped file still lands where you
aimed. That alone took the halo from 0.25 to 13.5 per second, and the outermost
ring from exactly zero to 3.0.

Inside the disk, an **orbiting hot spot** does the rest. The streak field only
pushes a noise phase, which the eye cannot follow; a discrete feature it can.
Compact overdensities on near-ISCO orbits are the standard model for Sgr A\*'s
infrared flares — GRAVITY watched the centroid of one go round — and this one is
lensed like everything else, so its far-side image arcs over the shadow half an
orbit out of step with itself.

## Being eaten

A dropped file does not simply shrink and fade. Five things happen to it, and
each one is something that happens to real matter falling into a real hole.

**It approaches**, on a decaying spiral, already visibly distorted.

**It is torn apart.** Not by an explosion — by tides. The near side is pulled
harder than the far side (the force goes as 1/r³) and orbits faster (Kepler), so
a solid body is *sheared* into a stream. That is a tidal disruption, and it is
why the debris is swallowed piece by piece rather than all at once. The shear is
a pure function of radius, so it inverts exactly: given a point on screen, the
shader un-shears it to find which part of the object was there. No particles.

**It keeps dividing.** Block, then grit, then dust — a body does not shatter
once and stop while the tide is still winning.

**It joins the disk.** This is the part worth arguing for. Debris does not fall
straight in; it circularises, and the disk eats it afterwards. So the arc it was
delivered into brightens, heats, and briefly carries the colour of whatever the
thing used to be.

**The disk stays fed.** The bright patch shears round as it settles, spreading
from a bruise into a ring, and decays over about ten seconds. A real tidal
disruption flare runs for months; this is the same shape at a watchable rate.

Two consequences worth having. Dropping a file now leaves something behind for
ten seconds instead of nothing after two — drop a handful and you can see the
thing being fed. And it answers a question nobody thinks to ask but everybody
understands on sight: where the disk came from.

The object is drawn **in front of** the hole, not on the sky plane behind it.
It was behind at first, which was wrong twice over: the disk is opaque, so the
whole descent happened out of sight, and light from something falling in on the
viewer's side reaches the eye directly — there is nothing in between to bend it.
What happens to it is tidal, not optical.

## Why the disk's rotation is a phase, not a speed

The shader is handed an already-integrated `diskPhase` rather than a rate it
multiplies by time. Anything that modulates how fast the disk turns — a flare, a
bass note — would otherwise jump every streak at once the moment it changed,
because `time` is large by then and scaling it moves the whole pattern. The
original GLSL hits the same wall and warns about it. Integrating on the CPU
makes the rate free to vary with no visible seam.

The flare leans on **temperature** more than gain: extra gain mostly clips.

## Tonemapping, the photon ring, and the glow

`1 − exp(−c)` applied per channel is why everything used to go white. The moment
red clips, an amber disk with every filament in it becomes a flat white blob —
and a temperature change, the entire point of the flare, stops being visible
because there is no colour left to shift. It is also why the hot spot was
invisible for two rounds.

Mapping the *peak* and carrying the chroma through unchanged fixes all of it at
once. Total hue preservation would be wrong too — something genuinely that hot
really is white — so the bleach is kept, just moved far past the knee and made
gradual.

The **photon ring** is not a separate object: it is the stack of higher-order
images made by rays that wound around the photon sphere before escaping. Every
extra disk crossing is one more turn. They are the sharpest structure in the
picture and also the faintest, because the near disk absorbed them the whole
way, so `RING_GAIN` weights emission by image order to pull them back out
without inventing anything.

**Nothing may clip to white.** This is the single failure mode the render keeps
finding new ways to reach, and every instance of it has the same shape — some
quantity added to another until a channel saturates, taking the hue and every
bit of structure with it. Three separate fixes, all worth keeping:

- The tonemap maps *intensity* and carries the chroma through, instead of
  running `1 − exp(−c)` per channel. The bleach that remains starts an order of
  magnitude past the knee and never completes.
- The curve is **extended Reinhard, not exponential**. `1 − exp(−peak)` has far
  too steep a shoulder for this image — 0.95 by peak 3, 0.9997 by peak 8 — so
  every layer in the bright part of the disk (the streak bands, the stacked
  higher-order images, the photon ring) lands inside the top few percent of the
  range and merges into one flat sheet. Reinhard keeps those two at 0.83 and
  0.96 and only reaches white at the white point. Turning `EXPOSURE` down cannot
  fix it: that dims everything and the layers stay merged, because the problem
  is the shape of the curve rather than where the image sits on it.
- The disk is **screened** over the lensed background rather than added to it,
  so a bright wallpaper cannot push the sum flat.
- Bloom is screened too, and it is fed a **separate emission target** rather
  than the composed scene. Keying it on the scene meant the lensed wallpaper
  itself glowed: a pale sky sits around 0.8, clears any sensible threshold, and
  buries the widget in a halo that has nothing to do with the black hole.

**Sampling the lensed background** uses real screen-space derivatives and a
mipmapped copy of the capture, so the hardware can pick a mip that matches the
footprint. It is worth being precise about what that does and does not fix.
Measured across the widget, the footprint is about *one texel* almost
everywhere, rising to 4–16 only at the photon ring and the shadow's edge — so
there is usually no coarser level to pick, and correct mip selection cannot cure
the moiré a periodic test pattern produces. (Supersampling the lookup four ways
was tried and measured: no benefit, three extra fetches.) What it does fix is
the ring and the higher-order images, where the compression is real. Real screen
content is not periodic and does not beat the way a checkerboard does.

The disk's own higher-order images are softened by image order instead: each
further image packs a whole disk into a thinner ring, far past what the pixel
grid can carry, so fading their contrast is the cheapest honest antialiasing
available — the structure is still integrated, just not sharpened into aliasing.

**Bloom** is four extra passes — bright-pass and quarter-res downsample,
separable Gaussian, composite — because a glow has to come from neighbouring
pixels and a single fragment pass cannot see them. Half-float targets, since
nine summed taps band visibly at 8 bits. The composite has to raise alpha as
well as add colour: the widget's output is premultiplied, so light spilling past
the disk would otherwise be multiplied away against a transparent background and
never appear. Setting `BLOOM` to 0 skips the whole chain.

## Performance

The capture follows the widget: on macOS 14+ the stream is cropped to the
widget's rect via `SCStreamConfiguration.sourceRect`, so a 350 pt widget costs
under 2% of a full-screen capture, and dragging it re-aims the stream rather
than restarting it. On 13 the crop is fixed at stream creation, so it falls back
to capturing the whole display and indexing into it.

The shader itself measured **~3.9 ms per frame at 3840×2160** with a large hole
and `N_STEPS` 48; a widget-sized panel is a small fraction of that. `N_STEPS` in
Advanced is the dial if you need one. Pixels past the silhouette take an early
exit, and the starfield costs nothing while `STAR_GAIN` is 0.

## Working on it

`Sources/BlackHoleApp/BlackHole.metal` is compiled at launch (~200 ms), not at
build time — SwiftPM has no `.metal` build rule for an executable target. That
turns out to be the better trade: point `BLACKHOLE_METAL` at a working copy and
a relaunch is the whole edit loop.

```sh
BLACKHOLE_METAL=$PWD/Sources/BlackHoleApp/BlackHole.metal swift run
```

A compile error shows up in **Advanced…** with the Metal compiler's own message,
not as a black screen. Capture and permission problems go to the unified log,
since stderr is discarded for a bundled app:

```sh
log stream --predicate 'subsystem == "dev.s13k.blackhole-app"'
```

The one contract to keep: `struct Uniforms` in `BlackHole.metal` and
`Uniforms.swift` must stay identical. Both are all-float on purpose — every
member is 4-byte aligned, so declaration order *is* the memory layout and the
two cannot silently disagree. Append in groups of four, shrink the pads, never
reorder.

## Differences from the Ghostty shader

The terminal version drives the hole's size and position from outside — the
context-window fill, a pomodoro clock, a roam box that grows out of a corner.
None of that is here: the widget is a fixed object you place, so `level`, the
Lissajous drift, the roam box and the work-area shield are gone, and the hole
sits at the centre of its frame. What remains is the physics and the look.

The cursor-color encoding is gone too. That whole mechanism existed only because
a terminal shader gets no custom uniforms.
