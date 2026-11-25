#pragma once
// SkinFlow public C API (render thread only).
// A renderer (Community Shaders' Advanced Skin) calls SkinFlow_GetSurface from
// BSLightingShader::SetupGeometry and binds the returned SRV for that draw.

#include <cstdint>

struct ID3D11ShaderResourceView;
namespace RE
{
	class BSRenderPass;
}

#define SKINFLOW_API_VERSION 4u

enum class SkinFlowView : std::uint32_t
{
	kSweat = 0,    // sweat drops, runs and sheen on the skin's wetness layer
	kGravity = 1,  // debug: speckle flowing downhill, red on steep skin, blue on flat
	kWater = 2,    // debug: the simulated water as a heat map
};

// How the sweat looks; the same for every surface (SkinFlow.ini [Look]).
struct SkinFlowLook
{
	float dropSize = 0.8f;  // drawn drop size multiplier (the simulation decides where drops are)
	float sheen = 1.0f;     // gloss of the film the water leaves on the skin
};

struct SkinFlowSurface
{
	// RGBA16F in the UV space of the drawn mesh: xy = downhill direction (length = sine of the
	// slope), z = outward normal .z, w = coverage.
	ID3D11ShaderResourceView* srv = nullptr;
	// RGBA32F, same UV space: x = simulated water (1 = a drop heavy enough to run down vertical skin),
	// y = trail wetness left where drops ran (1 fresh, fading out), z = a running drop's way to the
	// next texel (0..1), w = 1 + the direction of that texel (0 = resting). See Flow.hlsl.
	ID3D11ShaderResourceView* water = nullptr;
	float amount = 0.0f;   // sweat amount 0..1, before the renderer adds its own exertion wetness
	float uvScale = 0.0f;  // world units per UV unit on this surface, 0 while not measured yet
	SkinFlowView view = SkinFlowView::kSweat;
	SkinFlowLook look{};
};

extern "C"
{
	using SkinFlow_GetApiVersion_t = std::uint32_t (*)();
	// Returns false when this pass is not simulated skin (caller keeps its own path).
	using SkinFlow_GetSurface_t = bool (*)(RE::BSRenderPass* a_pass, SkinFlowSurface* a_out);
}
