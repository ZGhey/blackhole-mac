// BlackHole.metal — the geodesic tracer from blackhole.glsl, ported to Metal.
//
// Same physics, same numbers: every pixel near the hole integrates its own
// null geodesic through the Schwarzschild metric (Binet form,
// a = -(3/2) h² x / r⁵), and the shadow, lensing, photon ring, disk images
// and time dilation all fall out of that integration. Units: r_s = 1.
//
// What changed moving off Ghostty:
//   * the lensed "sky" is a background texture (desktop wallpaper / an image /
//     a flat void) instead of the terminal's own contents
//   * every tunable is a uniform, not a compile-time const — the control panel
//     drives them live, with no recompile
//   * the size driver is one float `level` (0..1, or <0 = hidden) computed on
//     the CPU, so manual / Claude / pomodoro / system-metric sources all share
//     the same geometry path (what the GLSL called token mode)
//
// Metal notes: fragment [[position]] has its origin at the top-left, which is
// the same top-down convention Ghostty's fragCoord uses, so the y handling
// below is unchanged from the GLSL.

#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------- uniforms --
// Mirrors `Uniforms` in Uniforms.swift EXACTLY. All-float by design: every
// member is 4-byte aligned, so declaration order is the memory layout and the
// two structs can't silently disagree. Append in groups of four and shrink the
// pads; never reorder.
struct Uniforms {
    float time, resX, resY, halo;
    float lensDepth, lensFalloff, starGain, diskPhase;
    float diskInner, diskOuter, diskIncl, diskRoll;
    float diskGain, diskOpacity, diskTemp, dopplerMix;
    float diskBeam, diskSpeed, diskWind, diskContrast;
    float exposure, flare, nSteps, bgDim;
    float bgScaleX, bgScaleY, bgOffX, bgOffY;
    float skyAlpha, audio, spotGain, spotRadius;
    float driftX, driftY, lensBoost, ringGain;
    float fallX, fallY, fallSize, fallAlpha;
    float hover, fallTear, feedAngle, feedStrength;
    float feedR, feedG, feedB, pad0;
};

// The disk's rotation arrives as an already-integrated phase rather than a
// speed the shader multiplies by time. Anything that modulates the rate —
// swallowing a file, music — would otherwise jump the pattern the moment it
// changed, because `time` is large and scaling it moves every streak at once.
// Integrating on the CPU makes the rate free to vary without a visible seam.
//
// flare 0..1  a mass just crossed the horizon: the disk brightens and heats,
//             the way infalling matter really does release its potential energy
// audio 0..1  system audio envelope, when the disk is set to pulse with it

// The widget always composites over live screen content, so the shader has to
// say which pixels it actually claims. Output is premultiplied alpha:
//   skyAlpha 1 = the background texture is real content worth covering (the
//                screen capture), so the lensed disc is opaque
//            0 = there is nothing behind it (stars only), so only the shadow
//                and the disk's own light are drawn and the rest shows through
static inline float4 composite(float3 col, float alpha) {
    float a = clamp(alpha, 0.0f, 1.0f);
    return float4(col * a, a);   // CoreAnimation wants premultiplied alpha
}

// Critical impact parameter of a Schwarzschild hole, in r_s: rays under this
// fall in, and it is the apparent (shadow) radius seen from far away. Physics,
// not taste — deliberately not a uniform, so no slider can drift it.
constant float B_CRIT = 2.5980762f;
/// Where the silhouette begins to taper, as a fraction of its own radius, and
/// the hard ceiling on that radius in units of the panel's inscribed circle.
/// The taper is what makes the widget round instead of square — an AppKit
/// window is a rectangle, but nothing that reaches the screen has to be.
constant float PANEL_FADE_START = 0.80f;
constant float PANEL_FADE_MAX   = 0.49f;
/// How far from the centre the disk may reach lives in `diskRoom`, in the same
/// units. Presets disagree wildly about DISK_OUTER (7 r_s for Gargantua, 16 for
/// Blazar); scaling the hole down until the disk fits is what lets one widget
/// size hold every style without clipping the bright part. Raising it trades
/// warped background for ring.
constant float TAU = 6.2831853f;

// ------------------------------------------------------------------ helpers --
// GLSL mod: floored, so it stays positive for negative inputs. MSL's fmod
// truncates instead, which would break mirrorUV and the noise lattice wrap.
static inline float gmod(float x, float y) { return x - y * floor(x / y); }
static inline float2 gmod(float2 x, float y) { return x - y * floor(x / y); }

static inline float hash21(float2 p) {
    p = fract(p * float2(234.34f, 435.345f));
    p += dot(p, p + 34.23f);
    return fract(p.x * p.y);
}

// Value noise whose y lattice wraps every perY cells — used for the disk's
// angular dimension so the streaks tile seamlessly across the atan branch cut
// (perY must be an integer; y must advance by exactly perY per full turn).
static inline float vnoiseWrapY(float2 p, float perY) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    float y0 = gmod(i.y, perY), y1 = gmod(i.y + 1.0f, perY);
    return mix(mix(hash21(float2(i.x, y0)), hash21(float2(i.x + 1.0f, y0)), f.x),
               mix(hash21(float2(i.x, y1)), hash21(float2(i.x + 1.0f, y1)), f.x),
               f.y);
}

// mirrored repeat keeps lensed samples on-screen without edge smearing
static inline float2 mirrorUV(float2 u) { return 1.0f - abs(1.0f - gmod(u, 2.0f)); }

static inline float2 rot(float2 v, float a) {
    float c = cos(a), s = sin(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// blackbody color from temperature in Kelvin (Tanner Helland fit, normalized)
static inline float3 blackbody(float T) {
    float t = clamp(T, 1500.0f, 40000.0f) / 100.0f;
    float r = t <= 66.0f ? 1.0f
                         : clamp(1.292936f * pow(t - 60.0f, -0.1332047f), 0.0f, 1.0f);
    float g = t <= 66.0f ? clamp(0.3900816f * log(t) - 0.6318414f, 0.0f, 1.0f)
                         : clamp(1.1298909f * pow(t - 60.0f, -0.0755148f), 0.0f, 1.0f);
    float b = t >= 66.0f ? 1.0f
                         : (t <= 19.0f ? 0.0f
                                       : clamp(0.5432068f * log(t - 10.0f) - 1.1962540f, 0.0f, 1.0f));
    return float3(r, g, b);
}

// sparse procedural starfield indexed by ray direction — because it is
// sampled with the *bent* ray, stars smear into arcs around the hole for free.
// `gain` is folded in so a disabled starfield (the default, since there is a
// wallpaper to lens) costs nothing instead of an atan2 + asin + hash per pixel.
static inline float3 stars(float3 d, float time, float gain) {
    if (gain <= 0.0f) return float3(0.0f);
    float2 sph = float2(atan2(d.x, -d.z), asin(clamp(d.y, -1.0f, 1.0f)));
    float2 g   = sph * 40.0f;
    float2 id  = floor(g);
    float h    = hash21(id);
    if (h < 0.92f) return float3(0.0f);
    float2 f   = fract(g) - 0.5f;
    float2 off = (float2(hash21(id + 17.3f), hash21(id + 31.7f)) - 0.5f) * 0.7f;
    float spark = smoothstep(0.10f, 0.0f, length(f - off));
    float tw    = 0.7f + 0.3f * sin(time * (0.5f + 2.0f * hash21(id + 5.1f)) + 40.0f * h);
    float3 tint = mix(float3(1.0f, 0.82f, 0.60f), float3(0.75f, 0.85f, 1.0f), hash21(id + 2.9f));
    return tint * spark * tw * ((h - 0.92f) / 0.08f) * gain;
}

// Tonemap the *intensity*, not each channel.
//
// `1 - exp(-c)` applied per channel is why everything here goes white: the
// moment red clips, an amber disk with every filament in it becomes a flat
// white blob, and a temperature change — the whole point of the flare — stops
// being visible because there is no colour left to shift. Mapping the peak and
// carrying the chroma through unchanged keeps the hue all the way up.
//
// Total hue preservation is wrong too: something genuinely that hot really does
// look white. So the bleach is kept, just moved far past the knee and made
// gradual, instead of arriving the instant one channel saturates.
static inline float3 tonemap(float3 c, float exposure) {
    float3 x = max(c * exposure, 0.0f);
    float peak = max(x.r, max(x.g, x.b));
    if (peak <= 1e-5f) return float3(0.0f);
    // Extended Reinhard rather than 1 - exp(-peak). The exponential's shoulder
    // is far too steep for this image: it reaches 0.95 by peak 3 and 0.9997 by
    // peak 8, so every layer in the bright part of the disk — the streak bands,
    // the stacked higher-order images, the photon ring — lands inside the top
    // few percent of the range and merges into one flat sheet. This keeps them
    // separated (0.83 and 0.96 at the same two points) and only actually
    // reaches white at the white point.
    const float white = 9.0f;
    float mapped = peak * (1.0f + peak / (white * white)) / (1.0f + peak);
    mapped = clamp(mapped, 0.0f, 1.0f);
    float3 ratio = x / peak;
    // The bleach used to start at peak 1.2, which the shipped styles clear
    // immediately — so the disk went white almost everywhere and only the
    // outermost filaments kept any colour at all. Genuinely extreme light
    // should still wash out, but "genuinely extreme" is an order of magnitude
    // further along than that, and it never goes all the way.
    ratio = mix(ratio, float3(1.0f), smoothstep(3.0f, 20.0f, peak) * 0.65f);
    return ratio * mapped;
}

// The lensed background, told how big a footprint the pixel actually covers.
// uv is in screen space (0..1); bgScale/bgOff map it into whatever slice of the
// capture the widget is sitting on.
//
// A single point sample per pixel is fine for an unwarped copy and catastrophic
// for a lensed one: the magnification swings by orders of magnitude across the
// image, so near the ring a wide band of screen is squeezed into a few pixels
// and gets sampled far below its Nyquist rate. Against fine detail — which is
// to say against text, which is what is usually behind the widget — that turns
// into moiré, and because the hole drifts, moiré that crawls.
//
// Handing the hardware the real screen-space derivatives lets it pick the mip
// level that matches the footprint, which is exactly the problem mipmaps exist
// to solve. The derivatives are taken *before* mirrorUV folds the coordinate,
// or every fold would read as a seam of maximum blur, and clamped so a caustic
// cannot demand a mip that does not exist.
static inline float3 skySampleGrad(texture2d<float> bg, sampler smp,
                                   constant Uniforms &U, float2 uv,
                                   float2 ddx, float2 ddy) {
    float2 scale = float2(U.bgScaleX, U.bgScaleY);
    float2 t = uv * scale + float2(U.bgOffX, U.bgOffY);
    float2 gx = clamp(ddx * scale, -0.25f, 0.25f);
    float2 gy = clamp(ddy * scale, -0.25f, 0.25f);
    return bg.sample(smp, t, gradient2d(gx, gy)).rgb * U.bgDim;
}

// Whatever is currently falling in, painted onto the sky plane so the tracer
// bends it like everything else.
//
// The obvious way to animate a dropped file is a layer on top of the render:
// spiral it inward, shrink it, fade it. That reads as an icon animating over a
// picture of a black hole, because it is — nothing about it is lensed. Put the
// same sprite *into* the sky the geodesics are sampling and the physics does
// the work instead: it stretches along the shear, smears into an arc, throws a
// second image near the photon ring, and is genuinely gone once its light can
// no longer escape.
//
// The redshift comes free: the sprite's distance from the centre is known here,
// so the same 1/√(1 − r_h/r) that reddens everything else reddens it too.
/// Whatever is currently falling in, drawn *in front of* the hole.
///
/// It was on the sky plane at first, which was wrong twice over. Practically,
/// the disk is opaque, so the object spent its whole descent hidden behind it
/// and the tearing was invisible. Physically, something falling in on the
/// viewer's side sends its light straight to the eye — there is nothing between
/// them to bend it. What happens to it is tidal, not optical.
///
/// And tidal is the whole point. The near side is pulled harder than the far
/// side (the force goes as 1/r³) and orbits faster (Kepler), so a solid body is
/// sheared into a stream well before it arrives, comes apart along seams, and
/// is swallowed piece by piece rather than all at once. That has a name — a
/// tidal disruption event — and the debris crossing in the order it reaches the
/// horizon is exactly what makes it read as being eaten rather than deleted.
///
/// Returned premultiplied: rgb already scaled by a.
static inline float4 fallerOverlay(texture2d<float> faller, sampler smp,
                                   constant Uniforms &U, float2 p, float rh) {
    if (U.fallAlpha <= 0.002f) return float4(0.0f);

    // Polar around the hole, because the shear is a function of radius.
    float2 c = float2(U.fallX, U.fallY);
    float r0 = max(length(c), 1e-4f);
    float rr = max(length(p), 1e-5f);
    float a0 = atan2(c.y, c.x);
    float th = atan2(p.y, p.x);

    // A pure function of radius inverts exactly: given a point on screen,
    // un-shear it to find which part of the object was there. No particles.
    float lead = U.fallTear * (pow(r0 / rr, 1.5f) - 1.0f);
    float dth = th - a0 - lead;
    dth = atan2(sin(dth), cos(dth));            // wrap to [-pi, pi]

    float halfSize = max(U.fallSize, 1e-4f) * 0.5f;   // `half` is a type in MSL
    // Debris does not stay at one radius. The pieces come away with a spread of
    // orbital energies, the innermost bound most tightly, so the stream draws
    // out radially as well as around — and the fragments reach the horizon one
    // after another rather than the whole body arriving at once. Without this
    // they sit in the same narrow annulus and go in together, which is what
    // made it read as a block rather than a stream.
    // Debris does not stay at one radius, but it does not fly outward either:
    // the pieces that come away with less orbital energy fall *inward*, so the
    // stream is drawn toward the hole while its trailing edge stays roughly put.
    // Spreading both ways turned it into a fan opening away from the hole,
    // which is the opposite of being eaten.
    float sv = (rr - r0) / halfSize;             // across the stream
    if (sv < 0.0f) sv /= (1.0f + 2.2f * U.fallTear);
    float su = dth * r0 / halfSize;              // along it
    if (fabs(sv) > 1.0f || fabs(su) > 1.0f) return float4(0.0f);

    float2 s = float2(su, sv) * 0.5f + 0.5f;
    float4 sprite = faller.sample(smp, float2(s.x, 1.0f - s.y));
    if (sprite.a <= 0.004f) return float4(0.0f);

    // Cracks, not a dissolve: the eye reads gaps as breakage and a fade as fog.
    // The seams have to open completely — a half-transparent gap just looks
    // like the whole thing is fading, which is the effect this exists to avoid.
    // Narrow seams, and more of them as it goes: a body does not shatter once,
    // it keeps dividing while the tide keeps winning — block, then grit, then
    // dust. Wide gaps would scatter it into confetti, and the point is that this
    // is a thing coming apart, not a thing dissolving.
    float chunks = 4.0f + 7.0f * clamp(U.fallTear, 0.0f, 1.1f);
    float2 cell = fract(s * chunks);
    float seam = min(min(cell.x, 1.0f - cell.x), min(cell.y, 1.0f - cell.y));
    float crack = smoothstep(0.03f, 0.11f, seam);
    float torn = mix(1.0f, crack, clamp(U.fallTear * 2.2f, 0.0f, 1.0f));

    // Redshift from *this* sample's radius, not the object's centre, so the
    // leading edge reddens, dims and goes out first.
    float escape = max(1.0f - rh / max(rr, rh * 1.005f), 0.0f);
    float3 tint = mix(float3(1.0f, 0.16f, 0.05f), float3(1.0f), sqrt(escape));
    // Redshift dims it, but not so fast that the disruption happens in the
    // dark — the fragments should still be legible while they come apart.
    float a = clamp(sprite.a * U.fallAlpha * torn * pow(escape, 0.22f), 0.0f, 1.0f);
    return float4(sprite.rgb * tint * a, a);
}

// ------------------------------------------------------------------ vertex --
struct VSOut {
    float4 pos [[position]];
};

/// The scene writes two targets: what you see, and — separately — only the
/// light the disk emitted.
///
/// Bloom has to key on the second. Keying on the first means the *lensed
/// wallpaper* blooms, and over anything pale that is most of the frame: a
/// light sky sits around 0.8, sails past any sensible threshold, and buries the
/// widget in a white halo that has nothing to do with the black hole. The
/// background is a copy of your screen and is already exposed correctly. Only
/// emission should glow.
struct SceneOut {
    float4 color [[color(0)]];
    float4 emission [[color(1)]];
};

// One oversized triangle covering the clip cube — no vertex buffer needed.
vertex VSOut blackholeVertex(uint vid [[vertex_id]]) {
    VSOut o;
    o.pos = float4(vid == 1 ? 3.0f : -1.0f,
                   vid == 2 ? 3.0f : -1.0f, 0.0f, 1.0f);
    return o;
}

// ---------------------------------------------------------------- fragment --
static inline SceneOut sceneOut(float4 color, float3 emission) {
    SceneOut o;
    o.color = color;
    o.emission = float4(emission, 1.0f);
    return o;
}

fragment SceneOut blackholeFragment(VSOut in [[stage_in]],
                                    constant Uniforms &U [[buffer(0)]],
                                    texture2d<float> bg [[texture(0)]],
                                    texture2d<float> faller [[texture(1)]],
                                    sampler smp [[sampler(0)]]) {
    float2 res   = float2(U.resX, U.resY);
    float2 uv    = in.pos.xy / res;
    float aspect = res.x / res.y;

    // disk extent in r_s, sanitized: the inner edge stays outside the photon
    // sphere (1.5 r_s) where circular orbits stop making sense
    float rin  = max(U.diskInner, 1.6f);
    float rout = max(U.diskOuter, rin + 0.5f);

    // ---- size ----
    // The composition always fills the widget, so the window *is* the visible
    // disc and there is no dead border to catch on the edge of a screen. That
    // leaves exactly one thing to decide here: how much lensed background rings
    // the disk. Everything else follows.
    //
    // The extent measured is what actually glows, not the nominal outer edge:
    // emission is faded out by rout*0.70 (see the band term at the crossing),
    // so fitting rout would hand roughly a third of the frame to disk that
    // emits nothing — which is what made the ring look small inside an
    // oversized warp.
    float lit = mix(rin, rout, 0.78f);
    float halo = clamp(U.halo, 1.0f, 3.0f);
    float haloRadius = PANEL_FADE_MAX;
    float diskExtent = haloRadius / halo;
    float rh = (diskExtent * B_CRIT) / lit;

    // The hole wanders a little inside its frame, on the Lissajous the GLSL
    // used to drift it across a whole terminal — two incommensurate sines per
    // axis, so the path never repeats. Kept small: the lensed background is a
    // static mapping of whatever is behind the widget, so *nothing* out in the
    // halo moves unless the warp field itself does, and the drop target should
    // still be roughly where you aimed. The silhouette stays centred on the
    // window, so the taper is unaffected.
    float2 center = float2(0.5f, 0.5f) + float2(U.driftX, U.driftY);

    // An accretion flare is a real brightening — but the shipped styles already
    // sit near the top of the tonemap, so leaning on gain just clips the disk
    // to a white blob and throws away every filament. Most of the effect comes
    // from temperature instead: hotter gas shifts the blackbody toward blue-
    // white, which reads as "that just got violent" while the structure
    // survives. Audio nudges the same two dials, so the two compose.
    // hover: the pointer is near. Small and sustained, where a flare is large
    // and brief — it should read as the hole noticing you, not reacting.
    float gainBoost = 1.0f + 0.55f * U.flare + 0.30f * U.audio + 0.30f * U.hover;
    float tempBoost = 1.0f + 0.85f * U.flare + 0.10f * U.audio + 0.14f * U.hover;

    // aspect-corrected frame centred on the hole (y in units of widget height)
    float2 p   = (uv - center) * float2(aspect, 1.0f);
    float plen = length(p);

    // screen <-> world mapping: the shadow's true angular size is B_CRIT r_s,
    // and we want it rh widget-heights wide, so 1 widget-height = W
    // Schwarzschild radii. pr is the pixel in world units, y-up, rolled.
    float W   = B_CRIT / rh;
    float2 pr = rot(float2(p.x, -p.y), U.diskRoll) * W;
    float b   = length(pr);            // the ray's impact parameter, in r_s

    // Distance window: real lensing falls off as 1/b and never stops, which
    // would warp the entire widget out to its corners. Fading it out a few disk
    // diameters away is deliberately unphysical.
    float wx = plen / max(U.lensFalloff * rh, 1e-4f);
    float window = exp(-wx * wx);

    // Radial silhouette. The halo runs several times wider than the widget, so
    // without this the window border slices through the warp and the widget
    // reads as a square — worse, the clipped band is an opaque copy of the
    // screen one capture-frame stale, which shows as a lagging rectangle over
    // anything moving underneath. Tapering the *displacement* ends the warp
    // smoothly, and since the early-out below keys on the same factor,
    // everything past the taper falls to alpha 0 and the widget stops existing
    // there. Alpha rides the taper too, so the copy crossfades into the real
    // screen instead of ending on a visible rim.
    float rNorm = length((uv - 0.5f) * float2(aspect, 1.0f)) / haloRadius;
    float silhouette = 1.0f - smoothstep(PANEL_FADE_START, 1.0f, rNorm);
    window *= silhouette;

    // In front of everything, so it is computed before any early-out can
    // discard the pixel and applied at every exit.
    float4 fall = fallerOverlay(faller, smp, U, p, rh);

    float bmax = rout + 3.0f;             // rays beyond this can't touch the disk
    float Z0   = max(14.0f, rout + 5.0f); // camera distance (shared with the tracer)

    // ================= far field: analytic weak deflection ==================
    // The geodesic region's rays start at the finite camera z = Z0 and get
    // projected back onto the sky plane, so they bend *less* than the textbook
    // alpha = 2 r_s/b from infinity — using that raw leaves a ~20% displacement
    // jump at the handoff radius, a visible circular seam. This is the same
    // finite-camera mapping, fitted against the integrator (sub-1% at the
    // boundary): disp = (2/b)(1.29u + 0.07)(L - 2.14u + 0.75) in world units,
    // with u = Z0/sqrt(Z0^2 + b^2).
    if (b >= bmax) {
        // Past the taper, or far enough out that the displacement is a fraction
        // of a pixel: hand the frame back untouched. On a widget-sized panel
        // that is most of the corners, and it saves three texture samples plus
        // the deflection math each.
        if (window < 0.001f) {
            return sceneOut(composite(fall.a > 0.0f ? fall.rgb / fall.a : float3(0.0f), fall.a),
                            float3(0.0f));
        }

        float u    = Z0 * rsqrt(Z0 * Z0 + b * b);
        float defl = (2.0f / (W * W)) / max(plen, 1e-4f)
                   * (1.29f * u + 0.07f)
                   * max(U.lensDepth * U.lensBoost - 2.14f * u + 0.75f, 0.0f)
                   * window;
        float2 dir = p / max(plen, 1e-5f);
        // Derivatives of the unfolded coordinate, taken once for the whole
        // pixel rather than per colour channel.
        float2 base = center + (p - dir * defl) / float2(aspect, 1.0f);
        float2 ddx = dfdx(base), ddy = dfdy(base);
        float3 term;
        // mild chromatic aberration: blue bends a touch more than red; faded in
        // away from the handoff circle (the geodesic side has none)
        float ab = 0.035f * smoothstep(1.0f, 2.0f, b / bmax);
        for (int i = 0; i < 3; i++) {
            float k    = 1.0f + (float(i) - 1.0f) * ab;
            float2 sp  = p - dir * defl * k;
            float2 suv = mirrorUV(center + sp / float2(aspect, 1.0f));
            term[i]    = skySampleGrad(bg, smp, U, suv, ddx, ddy)[i];
        }
        // same starfield as the geodesic region, lit through the weak-field
        // bend so stars don't pop at the boundary circle
        float3 d = normalize(float3(-(pr / b) * (2.0f / b), -1.0f));
        float3 st = stars(d, U.time, U.starGain) * window;
        float aFar = max(U.skyAlpha * silhouette,
                         clamp(max(st.r, max(st.g, st.b)), 0.0f, 1.0f));
        float3 far = (term + st) * (1.0f - fall.a) + fall.rgb;
        return sceneOut(composite(far, max(aFar, fall.a)), st);
    }

    // ====================== near field: trace the geodesic ==================
    // Parallel rays from a distant camera at +z. The hole is at the origin,
    // r_s = 1. Integrate  x'' = -(3/2) h² x / r⁵  (exact Schwarzschild photon
    // bending; h = |x×v| is conserved, so it's computed once).
    float3 x = float3(pr, Z0);
    float3 v = float3(0.0f, 0.0f, -1.0f);
    float h2 = dot(pr, pr);

    // disk plane: normal tilted diskIncl about the screen x-axis
    float ci = cos(U.diskIncl), si = sin(U.diskIncl);
    float3 n  = float3(0.0f, si, ci);
    float3 e2 = float3(0.0f, ci, -si);   // in-plane axis completing (x̂, e2, n)
    float sdir = U.diskSpeed < 0.0f ? -1.0f : 1.0f;

    float3 emitc = float3(0.0f);         // accumulated disk light (HDR)
    float trans  = 1.0f;                 // transmittance toward the background
    int crossings = 0;                   // which image of the disk this is
    bool captured = false;
    float sPrev = dot(x, n);
    float3 xPrev = x;

    int steps = int(max(U.nSteps, 4.0f));
    for (int i = 0; i < steps; i++) {
        float r2 = dot(x, x);
        if (r2 < 1.0f) { captured = true; break; }      // through the horizon
        if (x.z < -Z0 && v.z < 0.0f) break;             // escaped out the back
        if (r2 > 4.0f * Z0 * Z0) break;                 // flung far sideways
        float r = sqrt(r2);
        // step scales with radius: fine near the photon sphere, coarse far out
        // (the far cap is loose — bending falls off as 1/r^4, and longer
        // approach/exit strides leave more of the step budget for the strongly
        // curved region)
        float dt = clamp(0.16f * r, 0.03f, 1.5f);
        // leapfrog (kick-drift-kick) keeps the near-critical orbits stable
        float3 a = -1.5f * h2 * x / (r2 * r2 * r);
        v += a * (0.5f * dt);
        x += v * dt;
        r2 = dot(x, x);
        r  = sqrt(r2);
        a  = -1.5f * h2 * x / (r2 * r2 * r);
        v += a * (0.5f * dt);

        // ---- thin-disk crossing: the ray pierced the disk plane ----
        float s = dot(x, n);
        if (s * sPrev < 0.0f && trans > 0.02f) {
            float tc  = sPrev / (sPrev - s);
            float3 xc = mix(xPrev, x, tc);
            float rc  = length(xc);
            if (rc > rin && rc < rout) {
                // The photon ring is not a separate object — it is the stack of
                // higher-order images, made by rays that wound around the
                // photon sphere before escaping. Every extra crossing is one
                // more turn, and those images are the thinnest, sharpest
                // structure in the whole picture. They are also the faintest,
                // because the near disk has been absorbing them the whole way,
                // so the disk's own glow swallows them. Boosting by image order
                // pulls the ring back out without inventing anything.
                crossings++;
                float ring = 1.0f + U.ringGain * (1.0f - exp(-float(crossings - 1)));

                float band = smoothstep(rin, rin * 1.25f, rc)
                           * (1.0f - smoothstep(rout * 0.70f, rout, rc));

                // disk-plane polar coords for the streak texture
                float phi   = atan2(dot(xc, e2), xc.x);
                float turns = phi / TAU;

                // Orbiting hot spot: a compact overdensity on a near-ISCO
                // orbit. This is the standard picture for Sgr A*'s infrared
                // flares — GRAVITY watched the centroid of one go round — and
                // it is what makes the ring read as *turning* rather than
                // shimmering. The streak field only pushes a noise phase, which
                // the eye cannot track; a discrete feature it can follow. The
                // spot is lensed like everything else, so its far-side image
                // arcs over the shadow half an orbit out of step with itself.
                float spot = 0.0f;
                if (U.spotGain > 0.0f) {
                    float rs    = clamp(U.spotRadius, rin, rout);
                    float kepS  = pow(rin / rs, 1.5f);
                    float glocS = sqrt(max(1.0f - 1.5f / rs, 0.02f));
                    // Same integrated phase as the streaks, so a flare or a
                    // bass note speeds the spot up in step with the disk.
                    float ang   = -U.diskPhase * kepS * glocS * sdir;
                    float dPhi  = phi - ang;
                    dPhi = atan2(sin(dPhi), cos(dPhi));      // wrap to [-pi, pi]
                    float dR    = (rc - rs) / max(rs * 0.30f, 0.2f);
                    spot = exp(-dPhi * dPhi / 0.34f - dR * dR * 0.5f) * U.spotGain;
                }
                float kep   = pow(rin / rc, 1.5f);
                // √(1 − 1.5/r): time runs slower for the inner orbits — the
                // pattern visibly freezes toward the inner edge
                float gloc  = sqrt(max(1.0f - 1.5f / rc, 0.02f));
                float swirl = rc * U.diskWind * 0.12f - U.diskPhase * kep * gloc * sdir;
                float streaks = vnoiseWrapY(float2(rc * 2.8f, turns * 19.0f + swirl * 3.0f), 19.0f) * 0.65f +
                                vnoiseWrapY(float2(rc * 1.0f, turns * 9.0f + swirl * 1.5f + 7.0f), 9.0f) * 0.35f;
                // Each further image packs a whole disk into a thinner ring,
                // so the streak field there is far past what the pixel grid can
                // carry. Fading the contrast by image order is the cheapest
                // honest antialiasing available — the structure is still
                // integrated, just not sharpened into aliasing.
                float soften = 1.0f / (1.0f + 0.85f * float(crossings - 1));
                streaks = 0.35f + U.diskContrast * soften * streaks * streaks;

                // relativistic Doppler + gravitational shift for gas on a
                // circular geodesic: g = √(1 − 1.5/r) / (1 − β·k̂), with the
                // photon direction at the crossing taken from the ray itself
                float3 gasdir = normalize(cross(n, xc)) * sdir;
                float beta    = clamp(rsqrt(max(2.0f * (rc - 1.0f), 0.2f)), 0.0f, 0.99f);
                float gg      = gloc / max(1.0f + beta * dot(gasdir, normalize(v)), 0.05f);
                gg = mix(1.0f, gg, U.dopplerMix);

                // Shakura–Sunyaev temperature profile, peak normalized to 1
                float xpr   = max(1.0f - sqrt(rin / rc), 0.0f);
                float tprof = pow(rin / rc, 0.75f) * pow(xpr, 0.25f) / 0.488f;
                // The spot is denser *and* hotter, which is what separates it
                // from the surrounding gas by colour as well as brightness.
                // What was swallowed does not simply vanish: the debris
                // circularises and *becomes* disk. This is the arc it was
                // delivered into — hotter, brighter, and briefly carrying the
                // colour of whatever it used to be. It shears round the disk as
                // it settles, so the patch spreads from a bright bruise into a
                // ring and fades. A real tidal disruption flare is months of
                // exactly this; here it is a few seconds.
                float feed = 0.0f;
                if (U.feedStrength > 0.001f) {
                    float dphi = phi - U.feedAngle;
                    dphi = atan2(sin(dphi), cos(dphi));
                    float width = mix(2.9f, 0.40f, clamp(U.feedStrength, 0.0f, 1.0f));
                    feed = U.feedStrength * exp(-dphi * dphi / (width * width));
                }
                float3 cbb  = blackbody(U.diskTemp * tempBoost * (1.0f + 0.45f * spot)
                                        * (1.0f + 0.5f * feed) * tprof * gg);
                cbb = mix(cbb, float3(U.feedR, U.feedG, U.feedB), clamp(feed * 0.45f, 0.0f, 1.0f));
                float boost = pow(gg, U.diskBeam);                 // relativistic beaming

                float density = band * streaks * (1.0f + spot);
                emitc += trans * cbb * (U.diskGain * gainBoost * (1.0f + 2.4f * feed)
                                        * ring * 2.2f * density * tprof * tprof * boost);
                trans *= 1.0f - clamp(U.diskOpacity * density, 0.0f, 1.0f);
            }
        }
        sPrev = s;
        xPrev = x;
    }
    // rays still wound up near the photon sphere when the budget ran out are as
    // good as captured
    if (!captured && dot(x, x) < 4.0f) captured = true;

    // ---- background: where did the escaped ray come from? ----
    // The projection is computed for every pixel, captured or not, so that the
    // derivatives below are taken in uniform control flow — a quad straddling
    // the shadow's edge would otherwise hand back nonsense gradients and pick a
    // mip at random.
    float3 d = normalize(v);
    // project the straight exit ray onto the sky plane at z = -lensDepth and
    // map back to screen space
    float tpl  = (-U.lensDepth * U.lensBoost - x.z) / min(d.z, -1e-3f);
    float3 hp  = x + d * tpl;
    float2 q   = rot(hp.xy, -U.diskRoll) / W;
    float2 sp  = float2(q.x, -q.y);
    // the *displacement* is faded by the window, never the color — a continuous
    // warp leaves no seam at the silhouette
    float2 warped = center + (p + (sp - p) * window) / float2(aspect, 1.0f);
    float2 nddx = dfdx(warped), nddy = dfdy(warped);

    float3 bgc = float3(0.0f);
    if (!captured) {
        bgc += stars(d, U.time, U.starGain) * window;
        if (d.z < -0.05f) {
            // rays bent past ~90° never reach the sky plane behind the hole;
            // they fade to the starfield instead of sampling garbage
            float toward = smoothstep(0.05f, 0.35f, -d.z);
            bgc += skySampleGrad(bg, smp, U, mirrorUV(warped), nddx, nddy) * toward;
        }
    }

    // disk light is HDR; tonemap it on top of the (untouched) background sample
    float3 glow = tonemap(emitc, U.exposure);
    float3 base = bgc * trans;
    // Screen, not add. Adding emission to a copy of a bright screen clips the
    // sum flat white and takes the disk's structure with it — over a pale
    // wallpaper the whole widget went to paper. Screen blending is the same
    // thing on a dark background and cannot exceed 1 on a light one, so the
    // disk stays legible over anything.
    float3 col = 1.0f - (1.0f - clamp(base, 0.0f, 1.0f)) * (1.0f - clamp(glow, 0.0f, 1.0f));
    // The shadow is opaque even with nothing behind it — a hole that swallowed
    // your windows should read as a hole, not as a gap in the widget.
    float alpha = silhouette * max(U.skyAlpha,
                                   max(clamp(max(glow.r, max(glow.g, glow.b)), 0.0f, 1.0f),
                                       captured ? 1.0f : 0.0f));
    // Over the top of everything — the hole included.
    col = col * (1.0f - fall.a) + fall.rgb;
    return sceneOut(composite(col, max(alpha, fall.a)), glow * silhouette);
}

// ------------------------------------------------------------------- bloom --
// Bright light spills. A lens, an eye and a camera all scatter some of it
// sideways, which is why something genuinely bright reads as bright rather than
// merely pale — and the accretion disk is the brightest thing here by a wide
// margin. A single fragment pass cannot do it: the glow has to come from
// neighbouring pixels, so this is a small offscreen chain — bright-pass and
// downsample, separable blur, composite — run by Renderer between the scene and
// the drawable.

struct BloomUniforms {
    float threshold, strength, texelX, texelY;
    float dirX, dirY, pad0, pad1;
};

/// Isolate what is bright enough to spill, at quarter resolution — the blur
/// that follows is wide and soft, so full resolution would be wasted work.
/// Fed the emission target, never the composed scene: see SceneOut.
fragment float4 bloomBright(VSOut in [[stage_in]],
                            constant BloomUniforms &B [[buffer(0)]],
                            texture2d<float> src [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    float2 uv = in.pos.xy * float2(B.texelX, B.texelY);
    // Four taps offset by half a source texel: a free box filter on the way
    // down, which stops the blur from crawling as the widget drifts.
    float2 h = float2(B.texelX, B.texelY) * 0.25f;
    float3 c = src.sample(smp, uv + float2(-h.x, -h.y)).rgb
             + src.sample(smp, uv + float2( h.x, -h.y)).rgb
             + src.sample(smp, uv + float2(-h.x,  h.y)).rgb
             + src.sample(smp, uv + float2( h.x,  h.y)).rgb;
    c *= 0.25f;
    // Knee rather than a hard cut, or the glow develops a visible edge where
    // the disk crosses the threshold.
    float lum = max(c.r, max(c.g, c.b));
    float w = smoothstep(B.threshold, B.threshold + 0.25f, lum);
    return float4(c * w, 1.0f);
}

/// One axis of a separable Gaussian. Two passes, nine taps each, which is
/// cheaper and wider than any single-pass kernel of the same quality.
fragment float4 bloomBlur(VSOut in [[stage_in]],
                          constant BloomUniforms &B [[buffer(0)]],
                          texture2d<float> src [[texture(0)]],
                          sampler smp [[sampler(0)]]) {
    float2 uv = in.pos.xy * float2(B.texelX, B.texelY);
    float2 step = float2(B.dirX, B.dirY) * float2(B.texelX, B.texelY);
    const float w[5] = { 0.2270270f, 0.1945946f, 0.1216216f, 0.0540541f, 0.0162162f };
    float3 c = src.sample(smp, uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        float2 o = step * float(i) * 1.6f;
        c += src.sample(smp, uv + o).rgb * w[i];
        c += src.sample(smp, uv - o).rgb * w[i];
    }
    return float4(c, 1.0f);
}

/// Scene plus glow. The widget's colour is premultiplied, so the glow has to
/// raise alpha as well — otherwise light spilling past the disk would be
/// multiplied away against a transparent background and never appear at all.
fragment float4 bloomComposite(VSOut in [[stage_in]],
                               constant BloomUniforms &B [[buffer(0)]],
                               texture2d<float> scene [[texture(0)]],
                               texture2d<float> bloom [[texture(1)]],
                               sampler smp [[sampler(0)]]) {
    float2 uv = in.pos.xy * float2(B.texelX, B.texelY);
    float4 s = scene.sample(smp, uv);
    float3 g = bloom.sample(smp, uv).rgb * B.strength;
    float ga = clamp(max(g.r, max(g.g, g.b)), 0.0f, 1.0f);
    float a = clamp(s.a + ga * (1.0f - s.a), 0.0f, 1.0f);
    // Screen, not add. Adding drives whichever channel is already highest to 1
    // first and the rest after it, turning a bright amber disk white from the
    // inside out — the same clipping the tonemap just went to some trouble to
    // avoid. Premultiplied colour can never exceed its own alpha.
    float3 lit = 1.0f - (1.0f - clamp(s.rgb, 0.0f, 1.0f)) * (1.0f - clamp(g, 0.0f, 1.0f));
    return float4(min(lit, float3(a)), a);
}
