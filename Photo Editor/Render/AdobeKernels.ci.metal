//
//  AdobeKernels.ci.metal
//  Photo Editor
//
//  Core Image kernels implementing the Camera Raw adjustment stack.
//
//  Everything here receives linear scene-referred RGB in Core Image's working
//  space. Tone and colour operations that Adobe performs on display-referred
//  values encode to sRGB internally and decode on the way out, which is why
//  each kernel starts and ends in linear.
//
//  Compiled with -fcikernel / linked with -cikernel (see the target build
//  settings); the resulting default.metallib is loaded by CIKernelLibrary.
//

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

// MARK: - Shared helpers

constant float3 kLumaWeights = float3(0.2126, 0.7152, 0.0722);

static inline float luma(float3 c) {
    return dot(max(c, 0.0), kLumaWeights);
}

static inline float3 srgbEncode(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static inline float3 srgbDecode(float3 c) {
    c = max(c, 0.0);
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static inline float3 hueToRGB(float hueDegrees) {
    float h = fmod(fmod(hueDegrees, 360.0) + 360.0, 360.0) / 60.0;
    float x = 1.0 - abs(fmod(h, 2.0) - 1.0);
    if (h < 1.0) return float3(1.0, x, 0.0);
    if (h < 2.0) return float3(x, 1.0, 0.0);
    if (h < 3.0) return float3(0.0, 1.0, x);
    if (h < 4.0) return float3(0.0, x, 1.0);
    if (h < 5.0) return float3(x, 0.0, 1.0);
    return float3(1.0, 0.0, x);
}

static inline float3 rgbToHSV(float3 c) {
    float maxV = max(c.r, max(c.g, c.b));
    float minV = min(c.r, min(c.g, c.b));
    float delta = maxV - minV;

    float h = 0.0;
    if (delta > 1e-6) {
        if (maxV == c.r) {
            h = fmod((c.g - c.b) / delta, 6.0);
        } else if (maxV == c.g) {
            h = (c.b - c.r) / delta + 2.0;
        } else {
            h = (c.r - c.g) / delta + 4.0;
        }
        h *= 60.0;
        if (h < 0.0) h += 360.0;
    }
    float s = maxV > 1e-6 ? delta / maxV : 0.0;
    return float3(h, s, maxV);
}

static inline float3 hsvToRGB(float3 hsv) {
    float h = fmod(fmod(hsv.x, 360.0) + 360.0, 360.0) / 60.0;
    float s = clamp(hsv.y, 0.0, 1.0);
    float v = max(hsv.z, 0.0);
    float c = v * s;
    float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
    float m = v - c;

    float3 rgb;
    if (h < 1.0)      rgb = float3(c, x, 0.0);
    else if (h < 2.0) rgb = float3(x, c, 0.0);
    else if (h < 3.0) rgb = float3(0.0, c, x);
    else if (h < 4.0) rgb = float3(0.0, x, c);
    else if (h < 5.0) rgb = float3(x, 0.0, c);
    else              rgb = float3(c, 0.0, x);
    return rgb + m;
}

/// Weights for Adobe's eight hue bands. Adjacent band centres blend linearly,
/// so the weights always sum to one and a hue between Orange and Yellow picks
/// up a share of both — matching how the Color Mixer behaves.
static inline void hueBandWeights(float hueDegrees, thread float4 &w0, thread float4 &w1) {
    const float centers[9] = { 0.0, 30.0, 60.0, 120.0, 180.0, 240.0, 285.0, 330.0, 360.0 };

    float w[8];
    for (int i = 0; i < 8; ++i) w[i] = 0.0;

    float h = fmod(fmod(hueDegrees, 360.0) + 360.0, 360.0);
    for (int i = 0; i < 8; ++i) {
        float a = centers[i];
        float b = centers[i + 1];
        if (h >= a && h <= b) {
            float t = (b - a) > 1e-6 ? (h - a) / (b - a) : 0.0;
            w[i] += 1.0 - t;
            w[(i + 1) % 8] += t;
        }
    }

    w0 = float4(w[0], w[1], w[2], w[3]);
    w1 = float4(w[4], w[5], w[6], w[7]);
}

// MARK: - White balance and exposure

/// Applies the chromatic adaptation matrix and exposure gain in linear space,
/// where both are simple multiplications and nothing clips.
extern "C" float4 wbExposure(
    coreimage::sample_t s,
    float3 row0,
    float3 row1,
    float3 row2,
    float gain
) {
    float3 c = s.rgb;
    float3 balanced = float3(dot(row0, c), dot(row1, c), dot(row2, c));
    return float4(max(balanced * gain, 0.0), s.a);
}

// MARK: - Basic tone

/// Region weights for the four tone sliders, evaluated on the sRGB-encoded
/// luminance so the zones line up with what the histogram shows.
static inline float shadowWeight(float v) {
    float t = clamp(v / 0.5, 0.0, 1.0);
    return (1.0 - t) * (1.0 - t);
}

static inline float highlightWeight(float v) {
    float t = clamp((v - 0.5) / 0.5, 0.0, 1.0);
    return t * t;
}

static inline float blackWeight(float v) {
    float t = clamp(1.0 - v * 4.0, 0.0, 1.0);
    return t * t;
}

static inline float whiteWeight(float v) {
    float t = clamp((v - 0.6) / 0.4, 0.0, 1.0);
    return t * t;
}

/// Symmetric S-curve contrast pinned at 0, 0.5 and 1, so it can't shift the
/// midpoint or invert.
static inline float applyContrast(float v, float amount) {
    if (amount >= 0.0) {
        float k = clamp(amount, 0.0, 1.0);
        if (v <= 1.0) {
            float x = max(v, 0.0);
            float s = x * x * (3.0 - 2.0 * x);       // smoothstep S-curve
            return mix(x, s, k);
        }
        // Above white, continue with the curve's slope at 1.0 rather than
        // clamping. Clamping the input here flattened every highlight with
        // headroom to pure white, which showed up as hard-edged blown patches
        // around the sun where a smooth rolloff belongs.
        return 1.0 + (v - 1.0) * (1.0 - k);
    }
    // The reduced-contrast form is linear, so it's safe above 1.0 as it is.
    float flat = 0.5 + (v - 0.5) * 0.45;
    return mix(v, flat, clamp(-amount, 0.0, 1.0));
}

/// Exposure is already applied upstream; this is Contrast plus the four
/// Highlights / Shadows / Whites / Blacks sliders.
///
/// The region sliders contribute an offset derived from luminance and applied
/// equally to all three channels, which keeps hue stable. Contrast then runs
/// per channel, which is why raising it also raises apparent saturation —
/// the same behaviour Camera Raw has.
extern "C" float4 basicTone(
    coreimage::sample_t s,
    float contrast,
    float highlights,
    float shadows,
    float whites,
    float blacks,
    float shadowTint
) {
    float3 e = srgbEncode(s.rgb);
    float v = clamp(luma(e), 0.0, 1.0);

    float sw = shadowWeight(v);

    float offset = 0.0;
    offset += shadows    * 0.30 * sw;
    offset += highlights * 0.30 * highlightWeight(v);
    offset += blacks     * 0.22 * blackWeight(v);
    offset += whites     * 0.22 * whiteWeight(v);

    float3 toned = e + offset;

    // Calibration's Shadow Tint: green at negative, magenta at positive,
    // falling off with the same weighting as the Shadows slider.
    if (abs(shadowTint) > 1e-4) {
        float t = shadowTint * 0.05 * sw;
        toned += float3(t, -t, t);
    }

    if (abs(contrast) > 1e-4) {
        toned = float3(applyContrast(toned.r, contrast),
                       applyContrast(toned.g, contrast),
                       applyContrast(toned.b, contrast));
    }

    return float4(srgbDecode(max(toned, 0.0)), s.a);
}

// MARK: - Colour mixer, vibrance, saturation, B&W

/// Eight-band HSL, global vibrance/saturation, and the black-and-white
/// channel mixer. Band values arrive as two float4s each, in ColorBand order.
extern "C" float4 colorMixer(
    coreimage::sample_t s,
    float4 hue0, float4 hue1,
    float4 sat0, float4 sat1,
    float4 lum0, float4 lum1,
    float4 gray0, float4 gray1,
    float vibrance,
    float saturation,
    float monochrome
) {
    float3 e = srgbEncode(s.rgb);
    float3 hsv = rgbToHSV(e);

    float4 w0, w1;
    hueBandWeights(hsv.x, w0, w1);

    if (monochrome > 0.5) {
        float mixAmount = (dot(w0, gray0) + dot(w1, gray1)) / 100.0;
        float base = luma(e);
        // Scale by saturation so neutral pixels are untouched — a grey wall
        // shouldn't move when you drag the Red slider.
        float gray = base * (1.0 + mixAmount * hsv.y);
        return float4(srgbDecode(float3(max(gray, 0.0))), s.a);
    }

    float hueShift = dot(w0, hue0) + dot(w1, hue1);
    float satAdjust = dot(w0, sat0) + dot(w1, sat1);
    float lumAdjust = dot(w0, lum0) + dot(w1, lum1);

    // Fade the band adjustments out as a pixel approaches neutral.
    //
    // An achromatic pixel has no meaningful hue — R≈G≈B means the hue angle is
    // whatever the noise says — so it must not pick up a band's adjustment.
    // Without this, a near-white sky gets its luminance scaled by whichever
    // band its noisy hue happens to land in, and because neighbouring bands
    // carry different values the result is dark contour lines tracing the band
    // boundaries. Adobe's HSL leaves neutrals alone for exactly this reason.
    float bandWeight = smoothstep(0.0, 0.08, hsv.y);

    // ±100 on a band hue slider spans roughly ±30° in Camera Raw.
    hsv.x += hueShift * 0.30 * bandWeight;
    // Saturation stays multiplicative — that's already self-limiting on a
    // near-grey pixel, and weighting it too would blunt pale colours.
    hsv.y *= 1.0 + satAdjust / 100.0;
    hsv.z *= 1.0 + lumAdjust / 100.0 * 0.55 * bandWeight;

    // Vibrance protects already-saturated colours; saturation doesn't.
    if (abs(vibrance) > 1e-4) {
        hsv.y *= 1.0 + (vibrance / 100.0) * (1.0 - clamp(hsv.y, 0.0, 1.0));
    }
    if (abs(saturation) > 1e-4) {
        hsv.y *= 1.0 + saturation / 100.0;
    }

    hsv.y = clamp(hsv.y, 0.0, 1.0);
    hsv.z = max(hsv.z, 0.0);

    return float4(srgbDecode(hsvToRGB(hsv)), s.a);
}

// MARK: - Colour grading

static inline float3 tintZone(float3 c, float hue, float sat, float lum, float weight) {
    if (weight <= 1e-4) return c;

    if (sat > 1e-4) {
        float3 target = hueToRGB(hue);

        // The tint is added as a chroma direction with zero luminance, so it
        // shifts hue without touching brightness.
        //
        // The obvious alternative — rescaling the target up to the pixel's own
        // luminance — blows up for dark primaries. Blue's luminance is 0.07,
        // so a shadow hue anywhere near blue becomes a ~14x multiplier on the
        // blue channel and floods the whole image. This form is bounded by
        // construction: `chroma` never exceeds 1.
        float3 chroma = target - float3(luma(target));
        c += chroma * (clamp(sat / 100.0, 0.0, 1.0) * weight * 0.5);
    }
    if (abs(lum) > 1e-4) {
        c *= 1.0 + (lum / 100.0) * 0.6 * weight;
    }
    return max(c, 0.0);
}

/// Three-way colour grading. `blending` widens or narrows the overlap between
/// the shadow, midtone and highlight zones; `balance` slides the boundary
/// between the shadow and highlight zones.
extern "C" float4 colorGrade(
    coreimage::sample_t s,
    float3 shadowHSL,
    float3 midtoneHSL,
    float3 highlightHSL,
    float3 globalHSL,
    float blending,
    float balance
) {
    float3 e = srgbEncode(s.rgb);
    float v = clamp(luma(e), 0.0, 1.0);

    float pivot = 0.5 + clamp(balance, -100.0, 100.0) / 100.0 * 0.35;
    // Blending 0 gives hard zones, 100 gives a wide crossfade.
    float spread = mix(0.08, 0.55, clamp(blending, 0.0, 100.0) / 100.0);

    float shadowW = 1.0 - smoothstep(max(pivot - spread, 0.0), pivot + spread, v);
    float highlightW = smoothstep(max(pivot - spread, 0.0), min(pivot + spread, 1.0), v);
    float midW = max(0.0, 1.0 - shadowW - highlightW);

    float3 c = e;
    c = tintZone(c, shadowHSL.x, shadowHSL.y, shadowHSL.z, shadowW);
    c = tintZone(c, midtoneHSL.x, midtoneHSL.y, midtoneHSL.z, midW);
    c = tintZone(c, highlightHSL.x, highlightHSL.y, highlightHSL.z, highlightW);
    c = tintZone(c, globalHSL.x, globalHSL.y, globalHSL.z, 1.0);

    return float4(srgbDecode(max(c, 0.0)), s.a);
}

// MARK: - Clarity and texture

/// Local contrast against two blur radii: a wide one for Clarity (midtone
/// contrast) and a tight one for Texture (fine detail).
///
/// Clarity is weighted towards the midtones so it doesn't chew into blocked
/// shadows or blown highlights, which is what makes Adobe's version usable at
/// high settings.
extern "C" float4 clarityTexture(
    coreimage::sample_t s,
    coreimage::sample_t wideBlur,
    coreimage::sample_t fineBlur,
    float clarity,
    float texture
) {
    float3 e = srgbEncode(s.rgb);
    float v = clamp(luma(e), 0.0, 1.0);

    float3 result = e;

    if (abs(clarity) > 1e-4) {
        float3 wide = srgbEncode(wideBlur.rgb);
        float midtone = 1.0 - pow(abs(2.0 * v - 1.0), 1.6);
        result += (e - wide) * (clarity / 100.0) * 1.15 * midtone;
    }

    if (abs(texture) > 1e-4) {
        float3 fine = srgbEncode(fineBlur.rgb);
        // Texture is deliberately flat across the tonal range; it's a detail
        // control, not a contrast control.
        result += (e - fine) * (texture / 100.0) * 0.85;
    }

    return float4(srgbDecode(max(result, 0.0)), s.a);
}

// MARK: - Dehaze

/// Dark-channel-prior dehaze, simplified for real-time use.
///
/// `darkChannel` holds a blurred per-pixel minimum of the RGB channels, which
/// estimates how much airlight is in each region. Positive amounts subtract it
/// and rescale; negative amounts blend towards it to add atmosphere.
extern "C" float4 dehaze(
    coreimage::sample_t s,
    coreimage::sample_t darkChannel,
    float amount
) {
    float3 c = max(s.rgb, 0.0);
    float a = clamp(amount, -100.0, 100.0) / 100.0;
    float airlight = clamp(darkChannel.r, 0.0, 1.0);

    if (a > 0.0) {
        float transmission = clamp(1.0 - a * 0.85 * airlight, 0.12, 1.0);
        float3 recovered = (c - airlight * (1.0 - transmission)) / transmission;
        recovered = max(recovered, 0.0);

        // Removing haze reveals colour, so follow Adobe in nudging saturation
        // and contrast alongside it.
        float3 e = srgbEncode(recovered);
        float v = luma(e);
        e = mix(float3(v), e, 1.0 + a * 0.20);
        e = float3(applyContrast(e.r, a * 0.25),
                   applyContrast(e.g, a * 0.25),
                   applyContrast(e.b, a * 0.25));
        return float4(srgbDecode(max(e, 0.0)), s.a);
    }

    if (a < 0.0) {
        float k = -a * 0.6;
        float3 fog = float3(max(airlight, 0.15));
        return float4(mix(c, fog, k * airlight + k * 0.25), s.a);
    }

    return s;
}

// MARK: - Sharpening

/// Unsharp mask with Camera Raw's Detail and Masking behaviour.
///
/// `blurred` is a gaussian at the Radius setting; `edges` is a Laplacian used
/// to build the edge mask so flat areas — skies, skin — stay untouched at high
/// Masking values.
extern "C" float4 sharpen(
    coreimage::sample_t s,
    coreimage::sample_t blurred,
    coreimage::sample_t edges,
    float amount,
    float detail,
    float masking
) {
    float3 e = srgbEncode(s.rgb);
    float3 b = srgbEncode(max(blurred.rgb, 0.0));
    float3 highFreq = e - b;

    // Detail controls how much of the finest structure survives; low values
    // suppress halo-prone large edges.
    float detailMix = clamp(detail / 100.0, 0.0, 1.0);
    float3 shaped = highFreq * mix(0.55, 1.35, detailMix);

    float edgeStrength = abs(luma(abs(edges.rgb)));
    float maskAmount = clamp(masking / 100.0, 0.0, 1.0);
    float mask = mix(1.0, smoothstep(0.0, 0.06 + 0.30 * maskAmount, edgeStrength), maskAmount);

    float3 result = e + shaped * (amount / 100.0) * mask;
    return float4(srgbDecode(max(result, 0.0)), s.a);
}

// MARK: - Colour noise reduction

/// Keeps luminance from the source and takes chroma from a blurred copy,
/// which is how chroma noise is removed without softening detail.
extern "C" float4 colorNoiseReduction(
    coreimage::sample_t s,
    coreimage::sample_t blurred,
    float amount,
    float smoothness
) {
    float3 c = max(s.rgb, 0.0);
    float3 b = max(blurred.rgb, 0.0);

    float k = clamp(amount / 100.0, 0.0, 1.0) * mix(0.6, 1.0, clamp(smoothness / 100.0, 0.0, 1.0));
    if (k <= 1e-4) return s;

    float sourceLuma = luma(c);
    float blurLuma = max(luma(b), 1e-5);
    // Rescale the blurred colour to the source luminance, then blend.
    float3 chromaOnly = b * (sourceLuma / blurLuma);
    return float4(mix(c, chromaOnly, k), s.a);
}

// MARK: - Vignette

/// Post-crop vignette. Uses a superellipse so Roundness can go from a circle
/// through to a soft rectangle, matching Camera Raw's control.
extern "C" float4 postCropVignette(
    coreimage::sampler src,
    float4 extent,
    float amount,
    float midpoint,
    float feather,
    float roundness,
    float style,
    float highlightContrast,
    coreimage::destination dest
) {
    float4 s = src.sample(src.coord());
    float2 p = dest.coord();

    float2 center = extent.xy + extent.zw * 0.5;
    float2 halfSize = max(extent.zw * 0.5, float2(1.0));
    float2 n = (p - center) / halfSize;

    // Roundness: -100 tends towards a rectangle, +100 towards a circle.
    float exponent = mix(6.0, 2.0, clamp((roundness + 100.0) / 200.0, 0.0, 1.0));
    float radius = pow(pow(abs(n.x), exponent) + pow(abs(n.y), exponent), 1.0 / exponent);

    float start = clamp(midpoint / 100.0, 0.0, 1.0);
    float span = max(0.03, clamp(feather / 100.0, 0.0, 1.0) * 1.25);
    float falloff = smoothstep(start, start + span, radius);

    float k = falloff * clamp(amount, -100.0, 100.0) / 100.0;
    if (abs(k) <= 1e-4) return s;

    float3 c = max(s.rgb, 0.0);

    if (style > 2.5) {
        // Paint Overlay: straight blend towards black or white.
        float3 target = k < 0.0 ? float3(0.0) : float3(1.0);
        c = mix(c, target, min(abs(k), 1.0));
    } else {
        float factor = 1.0 + k;
        if (style < 1.5) {
            // Highlight Priority: ease off over bright pixels so speculars
            // and skies keep their punch.
            float brightness = clamp(luma(srgbEncode(c)), 0.0, 1.0);
            float protection = smoothstep(0.55, 1.0, brightness) * (k < 0.0 ? 0.65 : 0.0);
            factor = mix(factor, 1.0, protection);
        }
        c *= max(factor, 0.0);

        if (highlightContrast > 1e-4 && k < 0.0) {
            float3 e = srgbEncode(c);
            float boost = clamp(highlightContrast / 100.0, 0.0, 1.0) * falloff;
            e = float3(applyContrast(e.r, boost * 0.5),
                       applyContrast(e.g, boost * 0.5),
                       applyContrast(e.b, boost * 0.5));
            c = srgbDecode(e);
        }
    }

    return float4(c, s.a);
}

// MARK: - Grain

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);

    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Film grain. Size sets the noise cell size, Roughness mixes in a second
/// octave, and the effect is weighted towards the midtones the way Adobe's is
/// so clean blacks and blown highlights stay clean.
extern "C" float4 filmGrain(
    coreimage::sampler src,
    float amount,
    float grainSize,
    float roughness,
    float scale,
    coreimage::destination dest
) {
    float4 s = src.sample(src.coord());
    if (amount <= 1e-4) return s;

    float2 p = dest.coord() / max(scale, 0.05);
    float cell = mix(1.2, 6.0, clamp(grainSize / 100.0, 0.0, 1.0));

    float n = valueNoise(p / cell);
    float rough = clamp(roughness / 100.0, 0.0, 1.0);
    n = mix(n, (n + valueNoise(p / (cell * 0.45))) * 0.5, rough);

    float3 e = srgbEncode(max(s.rgb, 0.0));
    float v = clamp(luma(e), 0.0, 1.0);
    float weight = 1.0 - pow(abs(2.0 * v - 1.0), 1.4);

    float strength = (amount / 100.0) * 0.20 * weight;
    e += (n - 0.5) * strength;

    return float4(srgbDecode(max(e, 0.0)), s.a);
}

// MARK: - Utility

/// Per-pixel minimum of the RGB channels, the input to the dehaze estimate.
extern "C" float4 darkChannel(coreimage::sample_t s) {
    float m = min(s.r, min(s.g, s.b));
    return float4(m, m, m, s.a);
}
