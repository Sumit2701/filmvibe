//
//  FilmKernels.metal
//  FilmVibe
//
//  Core Image kernels (compiled with -fcikernel). All kernels receive and return
//  linear, extended-range RGB in Core Image's working space (linear sRGB primaries).
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

constant float3 kLuma = float3(0.2126f, 0.7152f, 0.0722f);

// ---------------------------------------------------------------------------
// Color space helpers
// ---------------------------------------------------------------------------

static inline float scbrt(float x) { return sign(x) * pow(abs(x), 1.0f / 3.0f); }

static inline float3 lin2oklab(float3 c) {
    float l = 0.4122214708f * c.r + 0.5363325363f * c.g + 0.0514459929f * c.b;
    float m = 0.2119034982f * c.r + 0.6806995451f * c.g + 0.1073969566f * c.b;
    float s = 0.0883024619f * c.r + 0.2817188376f * c.g + 0.6299787005f * c.b;
    l = scbrt(l); m = scbrt(m); s = scbrt(s);
    return float3(0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
                  1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
                  0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s);
}

static inline float3 oklab2lin(float3 lab) {
    float l = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    float m = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    float s = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    return float3( 4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
                  -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
                  -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s);
}

static inline float enc1(float x) {
    float a = abs(x);
    float e = a <= 0.0031308f ? 12.92f * a : 1.055f * pow(a, 1.0f / 2.4f) - 0.055f;
    return sign(x) * e;
}

static inline float dec1(float v) {
    float a = abs(v);
    float d = a <= 0.04045f ? a / 12.92f : pow((a + 0.055f) / 1.055f, 2.4f);
    return sign(v) * d;
}

static inline float3 enc3(float3 c) { return float3(enc1(c.r), enc1(c.g), enc1(c.b)); }
static inline float3 dec3(float3 v) { return float3(dec1(v.r), dec1(v.g), dec1(v.b)); }

static inline float angDist(float a, float b) {
    float d = a - b;
    return abs(atan2(sin(d), cos(d)));
}

// ---------------------------------------------------------------------------
// Tone curve
//
//  t = stops from middle grey.  Above grey the curve rises to white over `Th` stops
//  with a shoulder of strength `kh`; below grey it falls to black over `Tb` stops
//  with a toe of strength `ks`. Both halves meet at `vmid` with the same slope.
// ---------------------------------------------------------------------------

static inline float shoulderFn(float u, float k) {
    u = clamp(u, 0.0f, 1.0f);
    if (abs(k) < 1e-3f) return u;
    return (1.0f - exp(-k * u)) / (1.0f - exp(-k));
}

static inline float baseCurve(float Y, float4 t0, float ks) {
    float st = log2(max(Y, 1e-8f) / 0.18f);
    if (st >= 0.0f) {
        return t0.x + (1.0f - t0.x) * shoulderFn(st / t0.y, t0.z);
    }
    return t0.x * (1.0f - shoulderFn(-st / t0.w, ks));
}

/// Fujifilm-style Highlight / Shadow tone. Keeps black, white and middle grey (and the
/// slope at middle grey) fixed; bends the curve above / below it.
static inline float toneBumps(float v, float vmid, float hl, float sh) {
    if (v < vmid) {
        float x = v / vmid;
        float w = (1.0f - x) * (1.0f - x);
        return v * (1.0f - sh * w);
    }
    float u = (1.0f - v) / max(1.0f - vmid, 1e-4f);
    float w = (1.0f - u) * (1.0f - u);
    return 1.0f - (1.0f - v) * (1.0f - hl * w);
}

// ---------------------------------------------------------------------------
// Per-hue table (8 anchors, OkLCh degrees). Must match HueAnchor.degrees.
// ---------------------------------------------------------------------------

static inline float3 hueLookup(float h, float4 hs0, float4 hs1, float4 ss0, float4 ss1, float4 ls0, float4 ls1) {
    const float A[9] = {25.0f, 60.0f, 100.0f, 140.0f, 190.0f, 245.0f, 290.0f, 330.0f, 385.0f};
    const float HS[9] = {hs0.x, hs0.y, hs0.z, hs0.w, hs1.x, hs1.y, hs1.z, hs1.w, hs0.x};
    const float SS[9] = {ss0.x, ss0.y, ss0.z, ss0.w, ss1.x, ss1.y, ss1.z, ss1.w, ss0.x};
    const float LS[9] = {ls0.x, ls0.y, ls0.z, ls0.w, ls1.x, ls1.y, ls1.z, ls1.w, ls0.x};

    float hd = h * 57.29577951f;
    if (hd < 0.0f) hd += 360.0f;
    if (hd < A[0]) hd += 360.0f;

    int i = 7;
    for (int k = 0; k < 8; k++) {
        if (hd >= A[k] && hd < A[k + 1]) { i = k; }
    }
    float t = clamp((hd - A[i]) / (A[i + 1] - A[i]), 0.0f, 1.0f);
    t = t * t * (3.0f - 2.0f * t);
    return float3(mix(HS[i], HS[i + 1], t), mix(SS[i], SS[i + 1], t), mix(LS[i], LS[i + 1], t));
}

extern "C" {
namespace coreimage {

// ---------------------------------------------------------------------------
// Main film look: WB shift + exposure, film-simulation color, Color Chrome Effect,
// Color Chrome FX Blue, Color (saturation), monochrome conversion, tone curve
// (dynamic range, highlight, shadow), split toning.
//
//  gain   : rgb = channel gains (exposure × WB shift), w = 1 for monochrome
//  monoW  : rgb = monochrome channel weights
//  tone0  : vmid, Th (stops), kh, Tb (stops)
//  tone1  : ks, blackLift, highlight knee, whiteCap
//  tone2  : highlight bump, shadow bump
//  col0   : chroma scale, color chrome, fx blue
//  col1   : shadow saturation, highlight saturation
//  hs/ss/ls: per-hue hue shift (radians), saturation, lightness
//  split  : shadow tint (a,b), highlight tint (a,b)
//  tint   : mid tint (a,b), mono toning (a,b)
// ---------------------------------------------------------------------------
float4 fvFilmColor(sample_t s,
                   float4 gain, float4 monoW,
                   float4 tone0, float4 tone1, float4 tone2,
                   float4 col0, float4 col1,
                   float4 hs0, float4 hs1, float4 ss0, float4 ss1, float4 ls0, float4 ls1,
                   float4 split, float4 tint)
{
    float3 c = s.rgb * gain.rgb;
    bool mono = gain.w > 0.5f;

    // ---- Color (scene-linear, OkLCh) ----
    float3 lab = lin2oklab(c);
    float L = lab.x;
    float C = length(lab.yz);
    float h = atan2(lab.z, lab.y);

    if (!mono) {
        float3 adj = hueLookup(h, hs0, hs1, ss0, ss1, ls0, ls1);
        float cw = smoothstep(0.0f, 0.05f, C);
        h += adj.x * cw;
        C *= adj.y;
        L *= 1.0f + adj.z * cw;
        C *= col0.x;
    }

    // Color Chrome Effect: deepen highly saturated colors (more density / gradation).
    float ccw = smoothstep(0.06f, 0.20f, C) * smoothstep(0.2f, 0.7f, L);
    L *= 1.0f - col0.y * ccw;

    // Color Chrome FX Blue: deepen and enrich blues.
    float db = angDist(h, 4.2760f); // 245°
    float bw = exp(-(db * db) / 0.25f) * smoothstep(0.02f, 0.10f, C);
    L *= 1.0f - col0.z * bw;
    C *= 1.0f + col0.z * bw * 0.5f;

    c = oklab2lin(float3(L, C * cos(h), C * sin(h)));

    if (mono) {
        float y = dot(c, monoW.rgb);
        c = float3(y);
    }

    // ---- Tone (luminance curve, hue preserving) ----
    float Y = dot(c, kLuma);
    float v = baseCurve(Y, tone0, tone1.x);
    v = toneBumps(v, tone0.x, tone2.x, tone2.y);
    v = clamp(v, 0.0f, 1.0f);
    float Yd = dec1(v);
    if (Y > 1e-6f) {
        c *= Yd / Y;
    } else {
        c = float3(Yd);
    }

    // Path to white: bright saturated colors roll off toward neutral instead of clipping.
    float m = max(c.r, max(c.g, c.b));
    float knee = tone1.z;
    if (m > knee) {
        float x = (m - knee) / (1.0f - knee);
        float mm = knee + (1.0f - knee) * tanh(x);
        float t = clamp((mm - Yd) / max(m - Yd, 1e-5f), 0.0f, 1.0f);
        c = Yd + (c - Yd) * t;
    }

    // ---- Zone saturation & split toning ----
    float3 lab2 = lin2oklab(c);
    float wS = 1.0f - smoothstep(0.0f, 0.5f, v);
    float wH = smoothstep(0.5f, 1.0f, v);
    float wM = max(0.0f, 1.0f - wS - wH);
    float zs = mix(1.0f, col1.x, wS) * mix(1.0f, col1.y, wH);
    lab2.yz *= zs;
    float lw = min(1.0f, lab2.x / 0.35f);               // keep true black neutral
    float topFade = 1.0f - 0.6f * smoothstep(0.97f, 1.0f, v);
    lab2.yz += (split.xy * wS + tint.xy * wM) * lw + split.zw * wH * topFade;
    lab2.yz += tint.zw * (0.35f + 2.6f * v * (1.0f - v)) * lw;
    c = oklab2lin(lab2);

    // ---- Black lift / white cap ----
    float3 e = enc3(c);
    e = tone1.y + (tone1.w - tone1.y) * e;
    c = dec3(e);

    return float4(c, s.a);
}

// ---------------------------------------------------------------------------
// Clarity (large-radius local contrast) + Sharpness (small-radius unsharp mask),
// both on luminance in display space.
//   p.x clarity (negative = soft / glow), p.y sharpness (negative = soften)
// ---------------------------------------------------------------------------
float4 fvDetail(sample_t img, sample_t blurL, sample_t blurS, float4 p)
{
    float3 v = enc3(img.rgb);
    float3 vl = enc3(blurL.rgb);
    float3 vs = enc3(blurS.rgb);
    float y = dot(v, kLuma);
    float yl = dot(vl, kLuma);
    float ys = dot(vs, kLuma);

    if (p.x >= 0.0f) {
        float mask = smoothstep(0.02f, 0.3f, y) * (1.0f - smoothstep(0.75f, 1.02f, y));
        v += p.x * (y - yl) * mask;
    } else {
        float a = min(-p.x, 0.9f);
        v += -a * (y - yl);
        v = mix(v, vl, a * 0.25f);
    }

    if (p.y >= 0.0f) {
        v += p.y * (y - ys);
    } else {
        v = mix(v, vs, min(-p.y, 1.0f));
    }
    return float4(dec3(v), img.a);
}

// ---------------------------------------------------------------------------
// Film grain: monochrome, concentrated in the midtones.
//   p.x amplitude (display units), p.y midtone shape, p.z noise normalisation, p.w noise mean
// ---------------------------------------------------------------------------
float4 fvGrain(sample_t img, sample_t noise, float4 p)
{
    float3 v = enc3(img.rgb);
    float n = ((noise.r + noise.g + noise.b) - p.w) * p.z;
    float y = clamp(dot(v, kLuma), 0.0f, 1.0f);
    float w = pow(max(4.0f * y * (1.0f - y), 0.0f), p.y);
    w = max(w, 0.2f * (1.0f - y) * smoothstep(0.0f, 0.08f, y));
    v += p.x * n * w;
    return float4(dec3(v), img.a);
}

}
}
