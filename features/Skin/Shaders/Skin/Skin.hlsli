#ifndef __SKIN_HLSLI__
#define __SKIN_HLSLI__

#include "Common/BRDF.hlsli"
#include "Common/Color.hlsli"
#include "Common/LightingCommon.hlsli"
#include "Common/Math.hlsli"
#include "Common/Shading.hlsli"
#include "Common/SharedData.hlsli"

namespace Skin
{
	float CalculateCurvature(float3 N)
	{
		const float3 dNdx = ddx(N);
		const float3 dNdy = ddy(N);
		return length(float2(dot(dNdx, dNdx), dot(dNdy, dNdy)));
	}

#if defined(PSHADER)
	cbuffer SkinPerGeometry : register(b7)
	{
		float4 skinPerGeometry;
		float4 skinFlowParams;  // SkinFlow: x = surface bound, y = view (0 sweat, 1 gravity debug, 2 water heat map), z = sweat amount, w = world units per UV unit
		float4 skinFlowLook;    // SkinFlow: x = drop size, y = sheen, zw unused
	};
#endif
#if defined(SKIN)
	Texture2D<float4> TexSkinDetailNormal : register(t72);

	// SkinFlow.dll surface for this actor and UV layout (src/Features/SkinFlowBridge.h)
	Texture2D<float4> TexSkinFlow : register(t99);
	// Its simulated water: x = water (1 = a drop that runs down vertical skin), y = trail wetness,
	// z = a running drop's way to the next texel (0..1), w = 1 + its direction (0 = resting); Flow.hlsl
	Texture2D<float4> TexSkinFlowWater : register(t101);

#	if defined(PSHADER)
	/// Gravity texture at uv, bilinear over covered texels only (w = covered fraction).
	float4 SampleSkinFlow(float2 uv)
	{
		uint2 size;
		TexSkinFlow.GetDimensions(size.x, size.y);
		const float2 p = uv * size - 0.5;
		const int2 i = int2(floor(p));
		const float2 f = p - i;
		const int2 hi = int2(size) - 1;
		float4 sum = 0;
		float covered = 0;
		[unroll] for (int k = 0; k < 4; ++k)
		{
			const int2 o = int2(k & 1, k >> 1);
			const float4 t = TexSkinFlow.Load(int3(clamp(i + o, 0, hi), 0));
			const float w = (o.x ? f.x : 1 - f.x) * (o.y ? f.y : 1 - f.y) * t.w;
			sum += t * w;
			covered += w;
		}
		return covered > 0 ? float4(sum.xyz / covered, covered) : 0;
	}

	float SkinFlowValueNoise(float2 p)
	{
		const float2 i = floor(p);
		const float2 f = p - i;
		const float2 u = f * f * (3 - 2 * f);
		const float4 h = frac(sin(float4(dot(i, float2(127.1, 311.7)), dot(i + float2(1, 0), float2(127.1, 311.7)),
								   dot(i + float2(0, 1), float2(127.1, 311.7)), dot(i + 1, float2(127.1, 311.7)))) * 43758.5453);
		return lerp(lerp(h.x, h.y, u.x), lerp(h.z, h.w, u.x), u.y);
	}

	// ---- SkinFlow sweat ----
	// Sweat on the skin's wetness layer, built per pixel from the SkinFlow surface (downhill
	// direction) and the sweat amount: beads (spherical caps that sag downhill on steep skin),
	// drops that run down steep skin leaving a thin trail, and a thin film between them. The
	// pattern lives in this surface's UV space scaled to world units, so drops stay put on the
	// skin while it moves and keep their size from head to body. Drops smaller than a third of a
	// pixel fade into the film, so distance does not make them shimmer.

	struct SkinFlowWetness
	{
		bool active;    // SkinFlow covers this surface and owns its sweat (also at zero amount)
		float gloss;    // wetness glossiness (1 = water), max-combined with the built-in skin wetness
		float cover;    // how much the drop normal replaces the wet normal
		float3 normal;  // world-space normal of the water surface
	};

	static const float kSkinFlowBeadMin = 0.04;      // simulated water below this is film, not a bead
	static const float kSkinFlowDropRadius = 0.1;    // world units: a drop that just breaks loose (water 1), ~1.4 mm
	// Flow.hlsl kDirections: the neighbour a running drop is heading for (water.w - 1).
	static const int2 kSkinFlowDirections[8] = { int2(1, 0), int2(1, 1), int2(0, 1), int2(-1, 1), int2(-1, 0), int2(-1, -1), int2(0, -1), int2(1, -1) };

	struct SkinFlowDrop
	{
		float height;  // above the skin, world units
		float2 slope;  // height gradient along u and v (world units per world unit)
		float cover;   // antialiased footprint, 0..1
	};

	float4 SkinFlowRandom(int2 cell, uint seed)
	{
		uint4 v = uint4(asuint(cell), seed, 0x9E3779B9u) * 1664525u + 1013904223u;  // pcg4d
		v.x += v.y * v.w;
		v.y += v.z * v.x;
		v.z += v.x * v.y;
		v.w += v.y * v.z;
		v ^= v >> 16u;
		v.x += v.y * v.w;
		v.y += v.z * v.x;
		v.z += v.x * v.y;
		v.w += v.y * v.z;
		return float4(v) * (1.0 / 4294967296.0);
	}

	/// Where texel id's bead sits: a fixed random spot inside it, in world units on the skin.
	float2 SkinFlowSpot(int2 id, float cellWorld)
	{
		return (float2(id) + lerp(0.35, 0.65, SkinFlowRandom(id, 1u).xy)) * cellWorld;
	}

	/// Spherical cap of base radius r and height 0.4 r (a sweat bead's low contact angle), stretched by
	/// 'stretch' on its downhill side (f = unit downhill direction). d = pixel minus drop centre;
	/// footprint = world size of a pixel. Keeps the tallest drop at this pixel.
	void SkinFlowCap(float2 d, float r, float2 f, float stretch, float footprint, inout SkinFlowDrop best)
	{
		const float along = dot(d, f);
		const float2 across = d - along * f;
		const float e = along > 0 ? stretch : 1.0 + 0.25 * (stretch - 1.0);
		const float alongS = along / e;
		const float rho = sqrt(alongS * alongS + dot(across, across));
		const float visible = saturate(3.0 * r / footprint - 0.5);  // fades once the drop is under ~1/3 pixel wide
		const float cover = saturate((r - rho) / footprint + 0.5) * visible;
		if (cover <= 0)
			return;
		const float hc = 0.4 * r;  // low cap, round enough to catch its own highlight
		const float R = (r * r + hc * hc) / (2 * hc);
		const float root = sqrt(R * R - min(rho * rho, r * r));
		const float height = root - (R - hc);
		if (height < best.height)
			return;
		best.height = height;
		best.slope = -(alongS / e * f + across) / root * visible;
		best.cover = cover;
	}

	/// N = the skin's world normal before detail normals; exertion = Advanced Skin's own sweat and
	/// water wetness for this actor, shown as film on top of the simulated water.
	/// The drops are the simulation's (TexSkinFlowWater): each texel holding water is a bead whose
	/// volume is its water, at a fixed random spot in the texel; a running one slides towards the
	/// next texel's spot as the simulation moves it, stretched along its path. Between them the skin is dry except
	/// where water has not gathered into a bead yet and where drops ran (trails), as a thin film at
	/// the sheen level (a tent filter over the nearest 3x3 texels, so it is smooth).
	SkinFlowWetness GetSkinFlowWetness(float2 uv, float3 worldPosition, float3 N, float exertion, float time)
	{
		SkinFlowWetness o;
		o.active = false;
		o.gloss = 0;
		o.cover = 0;
		o.normal = N;

		// Screen derivatives before any branch.
		const float3 dpx = ddx(worldPosition);
		const float3 dpy = ddy(worldPosition);
		const float2 duvx = ddx(uv);
		const float2 duvy = ddy(uv);

		if (skinFlowParams.x <= 0.0 || skinFlowParams.y != 0.0 || skinFlowParams.w <= 0.0)
			return o;
		o.active = true;

		const float dropSize = skinFlowLook.x;
		const float4 g = SampleSkinFlow(saturate(uv));
		const float slope = saturate(length(g.xy));
		const float2 f = slope > 1e-3 ? normalize(g.xy) : float2(0, 1);

		// World directions of increasing u and v on the skin (cotangent frame from derivatives).
		const float3 px = cross(dpy, N);
		const float3 py = cross(N, dpx);
		const float side = dot(N, cross(dpx, dpy)) < 0 ? -1.0 : 1.0;
		float3 tu = (px * duvx.x + py * duvy.x) * side;
		float3 tv = (px * duvx.y + py * duvy.y) * side;
		tu *= rsqrt(max(dot(tu, tu), 1e-20));
		tv *= rsqrt(max(dot(tv, tv), 1e-20));

		uint2 size;
		TexSkinFlowWater.GetDimensions(size.x, size.y);
		const int2 hi = int2(size) - 1;
		const float cellWorld = skinFlowParams.w / float(size.x);  // world units per simulated texel
		const float2 c = saturate(uv) * float2(size);              // position in texels
		const float2 q = c * cellWorld;                            // world units on the skin
		const int2 base = int2(floor(c));
		const float footprint = max(max(length(dpx), length(dpy)), 1e-4);

		SkinFlowDrop best;
		best.height = 0;
		best.slope = 0;
		best.cover = 0;
		float film = 0;
		float trail = 0;
		float weights = 0;
		// 5x5: a running drop is drawn up to a texel past its own, towards the next one.
		[unroll] for (int y = -2; y <= 2; ++y)
		{
			[unroll] for (int x = -2; x <= 2; ++x)
			{
				const int2 id = base + int2(x, y);
				if (any(id < 0) || any(id > hi))
					continue;
				const float4 s = TexSkinFlowWater.Load(int3(id, 0));
				const float2 d = abs(float2(id) + 0.5 - c);
				const float w = saturate(1.5 - d.x) * saturate(1.5 - d.y);  // tent over the 3x3 nearest
				film += (s.x > kSkinFlowBeadMin ? 0.0 : s.x / kSkinFlowBeadMin) * w;  // water not gathered into a bead
				trail += s.y * w;
				weights += w;
				if (s.x > kSkinFlowBeadMin) {
					const float r = kSkinFlowDropRadius * dropSize * pow(clamp(s.x, kSkinFlowBeadMin, 2.0), 1.0 / 3.0);
					if (s.w >= 1.0) {
						// Running: slides from this texel's spot to the next one's as it gets there.
						const int2 step = kSkinFlowDirections[int(s.w) - 1];
						const float2 centre = lerp(SkinFlowSpot(id, cellWorld), SkinFlowSpot(id + step, cellWorld), s.z);
						SkinFlowCap(q - centre, r, normalize(float2(step)), 1.5, footprint, best);
					} else {
						SkinFlowCap(q - SkinFlowSpot(id, cellWorld), r, f, 1.0 + 0.9 * slope * r / (0.16 * dropSize), footprint, best);
					}
				}
			}
		}
		film = saturate(film / max(weights, 1e-4));
		trail = smoothstep(0.2, 0.9, trail / max(weights, 1e-4));

		const float2 s = best.slope;
		o.normal = normalize(N - (s.x * tu + s.y * tv));
		o.cover = best.cover;
		o.gloss = max(skinFlowLook.y * max(max(film, trail), saturate(exertion)), best.cover);
		return o;
	}

	/// Water debug view: the simulated water per texel, dark blue (dry) through cyan (film, growing
	/// beads) and yellow to white (a drop heavy enough to run), trails left by running drops in green.
	float3 SkinFlowWaterHeat(float2 uv)
	{
		uint2 size;
		TexSkinFlowWater.GetDimensions(size.x, size.y);
		const float2 s = TexSkinFlowWater.Load(int3(min(uint2(saturate(uv) * size), size - 1), 0)).xy;
		const float w = saturate(s.x);
		float3 heat = w < 0.5 ? lerp(float3(0.0, 0.03, 0.2), float3(0.0, 0.75, 0.9), w * 2.0) : lerp(float3(0.0, 0.75, 0.9), float3(1.0, 0.9, 0.1), w * 2.0 - 1.0);
		if (s.x >= 1.0)
			heat = float3(1, 1, 1);
		return heat + float3(0.0, 0.45, 0.05) * saturate(s.y) * (1.0 - w);
	}

	/// Debug views (1 gravity, 2 water). Gravity: a speckle pattern that slides downhill along the stored UV direction
	/// (flow-map advection: two phase-shifted copies cross-faded, so a small change in direction
	/// only moves the pattern a little), tinted red where steep and blue where flat; magenta =
	/// texel the gravity pass did not cover. Directions are in UV space, so the pattern breaks at
	/// UV seams; its motion must still point to the ground everywhere.
	bool GetSkinFlowDebugColor(float2 uv, float time, out float3 color)
	{
		color = 0;
		if (skinFlowParams.x <= 0.0 || skinFlowParams.y < 1.0)
			return false;
		const float4 g = SampleSkinFlow(saturate(uv));
		if (g.w <= 0.01) {
			color = float3(1, 0, 1);
			return true;
		}
		if (skinFlowParams.y == 2.0) {
			color = SkinFlowWaterHeat(uv);
			return true;
		}
		const float slope = saturate(length(g.xy));  // sine of the slope: 0 flat, 1 vertical
		const float kCellsPerUV = 96.0;
		const float kTravel = 3.0;  // cells moved per cycle on vertical skin
		const float phase0 = frac(time);
		const float phase1 = frac(time + 0.5);
		const float2 p = uv * kCellsPerUV;
		const float n0 = SkinFlowValueNoise(p - g.xy * kTravel * phase0);
		const float n1 = SkinFlowValueNoise(p - g.xy * kTravel * phase1 + 17.3);
		const float blend = abs(2.0 * phase0 - 1.0);  // weight of copy 1: zero when it wraps
		const float speckle = smoothstep(0.45, 0.85, lerp(n0, n1, blend));
		const float3 tint = lerp(float3(0.10, 0.30, 1.00), float3(1.00, 0.25, 0.05), slope);
		color = tint * (0.3 + 0.7 * speckle);
		return true;
	}
#	endif

	// [Jorge Jimenez, Diego Gutierrez 2015, "Separable Subsurface Scattering"]
	// https://www.iryoku.com/separable-sss/
	float3 SSSSTransmittance(float translucency, float sssWidth, float3 worldNormal, float3 light, float d)
	{
		/**
		* Calculate the scale of the effect.
		*/
		float scale = 8.25 * (1.0 - translucency) / sssWidth;

		/**
		* First we shrink the position inwards the surface to avoid artifacts:
		* (Note that this can be done once for all the lights)
		*/
		// float4 shrinkedPos = float4(worldPosition - 0.005 * worldNormal, 1.0);

		/**
		* Now we calculate the thickness from the light point of view:
		*/
		// float4 shadowPosition = mul(shrinkedPos, lightViewProjection);
		// float d1 = SSSSSampleShadowmap(shadowPosition.xy / shadowPosition.w).r; // 'd1' has a range of 0..1
		// float d2 = shadowPosition.z; // 'd2' has a range of 0..'lightFarPlane'
		// d1 *= lightFarPlane; // So we scale 'd1' accordingly:
		// float d = scale * abs(d1 - d2);
		d = scale * abs(d);  // Use the passed 'd' value instead of calculating it here.

		/**
		* Armed with the thickness, we can now calculate the color by means of the
		* precalculated transmittance profile.
		* (It can be precomputed into a texture, for maximum performance):
		*/
		float dd = -d * d;
		float3 profile = float3(0.233, 0.455, 0.649) * exp(dd / 0.0064) +
		                 float3(0.1, 0.336, 0.344) * exp(dd / 0.0484) +
		                 float3(0.118, 0.198, 0.0) * exp(dd / 0.187) +
		                 float3(0.113, 0.007, 0.007) * exp(dd / 0.567) +
		                 float3(0.358, 0.004, 0.0) * exp(dd / 1.99) +
		                 float3(0.078, 0.0, 0.0) * exp(dd / 7.41);

		/**
		* Using the profile, we finally approximate the transmitted lighting from
		* the back of the object:
		*/
		return profile * saturate(0.3 + dot(light, -worldNormal));
	}

	float3 DualSpecularGGX(float AverageRoughness, float Lobe0Roughness, float Lobe1Roughness, float LobeMix, float3 SpecularColor, float NdotL, float NdotV, float NdotH, float VdotH, out float3 F)
	{
		float D = lerp(BRDF::D_GGX(Lobe0Roughness, NdotH), BRDF::D_GGX(Lobe1Roughness, NdotH), LobeMix);
		float G = BRDF::Vis_SmithJointApprox(AverageRoughness, NdotV, NdotL);
		F = BRDF::F_Schlick(SpecularColor, VdotH);

		return D * G * F;
	}

	void SkinDirectLightInput(
		out DirectLightingOutput lightingOutput,
		DirectContext context,
		MaterialProperties material)
	{
		lightingOutput = (DirectLightingOutput)0;
		context.lightColor *= Color::PBRLightingCompensation * context.detailedShadow;

		const float3 N = context.worldNormal;
		const float3 V = context.viewDir;
		const float3 L = context.lightDir;
		const float3 H = context.halfVector;

		const float oNdotL = dot(N, L);
		float NdotL = clamp(oNdotL, 1e-5, 1.0);
		float NdotV = saturate(abs(dot(N, V)) + 1e-5);
		float NdotH = saturate(dot(N, H));
		float VdotH = saturate(dot(V, H));

		context.lightColor *= ApproximateDirectOcculusion(material.AO, NdotL);

		float averageRoughness = lerp(material.Roughness, material.RoughnessSecondary, material.SecondarySpecIntensity);

		lightingOutput.diffuse += context.lightColor * NdotL * BRDF::Diffuse_Burley(averageRoughness, NdotV, NdotL, VdotH);
		float3 F;
		float3 F0 = material.F0 * saturate(1 - material.Curvature);

		lightingOutput.specular += DualSpecularGGX(averageRoughness, material.Roughness, material.RoughnessSecondary, material.SecondarySpecIntensity, F0, NdotL, NdotV, NdotH, VdotH, F) * context.lightColor * NdotL;

		float2 specularBRDF = BRDF::EnvBRDF(averageRoughness, NdotV);
		lightingOutput.specular *= 1 + F0 * (1 / (specularBRDF.x + specularBRDF.y) - 1);
		lightingOutput.diffuse *= 1 - F;

		if (material.FuzzWeight > 0.0) {
			float3 FuzzF0 = material.FuzzColor * saturate(1 - material.Curvature);
			float fuzzD = BRDF::D_Charlie(material.FuzzRoughness, NdotH);
			float fuzzG = BRDF::Vis_Neubelt(NdotV, NdotL);
			float3 fuzzF = BRDF::F_Schlick(FuzzF0, VdotH);
			float3 fuzzSpecular = fuzzD * fuzzG * fuzzF * context.lightColor * NdotL;
			float2 fuzzSpecularBRDF = BRDF::EnvBRDFApproxLazarov(material.FuzzRoughness, NdotV);
			fuzzSpecular *= 1 + material.FuzzColor * (1 / (fuzzSpecularBRDF.x + fuzzSpecularBRDF.y) - 1);

			lightingOutput.specular += fuzzSpecular * material.FuzzWeight;
		}

		float3 sssTransmittance = SSSSTransmittance(
									  SharedData::skinData.sssParams.x,
									  SharedData::skinData.sssParams.y,
									  N,
									  L,
									  material.Thickness) *
		                          SharedData::skinData.sssParams.w;
		lightingOutput.transmission = min(sssTransmittance * context.lightColor * context.softShadow * material.BaseColor, context.lightColor);
	}

	void SkinIndirectLobeWeights(
		out IndirectLobeWeights lobeWeights,
		MaterialProperties material,
		IndirectContext context)
	{
		lobeWeights = (IndirectLobeWeights)0;

		const float3 N = context.worldNormal;
		const float3 V = context.viewDir;
		const float3 VN = context.vertexNormal;

		float NdotV = saturate(dot(N, V));

		float averageRoughness = lerp(material.Roughness, material.RoughnessSecondary, material.SecondarySpecIntensity);

		float2 specularBRDF = BRDF::EnvBRDF(averageRoughness, NdotV);

		lobeWeights.specular = material.F0 * specularBRDF.x + specularBRDF.y;

		lobeWeights.diffuse = material.BaseColor * (1.0 - lobeWeights.specular.x - lobeWeights.specular.y);
		lobeWeights.specular *= 1 + material.F0 * (1 / (specularBRDF.x + specularBRDF.y) - 1);

		float3 R = reflect(-V, N);
		float horizon = min(1.0 + dot(R, VN), 1.0);
		horizon *= horizon;
		lobeWeights.specular *= horizon;

		float3 diffuseAO = material.AO;
		float3 specularAO = SpecularAOLagarde(NdotV, material.AO, averageRoughness);

		diffuseAO = MultiBounceAO(material.BaseColor, diffuseAO.x).y;
		specularAO = MultiBounceAO(material.F0, specularAO.x).y;

		lobeWeights.diffuse *= diffuseAO;
		lobeWeights.specular *= specularAO;

		lobeWeights.specular *= saturate(1 - material.Curvature);
	}

	float FBM(float2 uv, float base_scale, int octaves, float lacunarity, float persistence, float z_offset_multiplier)
	{
		float total = 0.0;
		float frequency = base_scale;
		float amplitude = 1.0;
		float max_amplitude = 0.0;
		for (int i = 0; i < octaves; i++) {
			total += amplitude * (Random::perlinNoise(float3(uv * frequency, (float)i * z_offset_multiplier)) + 1.0) * 0.5;

			max_amplitude += amplitude;
			amplitude *= persistence;
			frequency *= lacunarity;
		}
		if (max_amplitude > 0.0) {
			return total / max_amplitude;
		}
		return 0.0;
	}

	float PerlinNoise(float2 uv, float scale, float lacunarity, float persistence, float strength)
	{
		if (strength <= 0.001f) {
			return 0.0f;
		}
		if (strength >= 0.999f) {
			return 1.0f;
		}
		int octaves = 5;
		float z_offset_multiplier = 7.375f;

		float noise_value = FBM(uv, scale, octaves, lacunarity, persistence, z_offset_multiplier);

		float dynamic_threshold = 1.0f - strength;

		float sweat_intensity = saturate((noise_value - dynamic_threshold) / strength);

		sweat_intensity = pow(sweat_intensity, 1.5f);

		if (strength > 0.8f) {
			sweat_intensity = sweat_intensity * saturate(0.99f - (strength - 0.8f) * 5.0f) + (strength - 0.8f) * 5.0f;
		}
		return pow(sweat_intensity, 0.1f);
	}
#endif

	float2 GetWetness(float z, float3 modelNormal)
	{
		if (skinPerGeometry.x == 0.f && skinPerGeometry.y == 0.f)
			return 0.f;

		float waterWet = 0.0f;
		float waterLevel = skinPerGeometry.z + skinPerGeometry.w;

		waterWet = skinPerGeometry.y * (1 - smoothstep(waterLevel - 2.5f, waterLevel + 2.5f, z));

		float sweatWet = skinPerGeometry.x;
#if !defined(SKIN)
		sweatWet *= 1.0f - saturate(dot(modelNormal, float3(0, 0, 1)));
#endif
		return float2(sweatWet, waterWet);
	}
}

#endif  // __SKIN_HLSLI__
