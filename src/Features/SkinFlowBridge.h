#pragma once

#include "SkinFlowAPI.h"

/**
 * @brief Optional external skin surface provider (SkinFlow.dll).
 *
 * When SkinFlow.dll is loaded and claims a skin pass, its per-actor surfaces (textures in the
 * UV space of the drawn mesh: gravity field at t99, simulated water at t101) are bound for that
 * draw, and the returned parameters tell Lighting.hlsl how to read them. Without the DLL nothing changes.
 */
class SkinFlowBridge
{
public:
	static constexpr uint32_t kTextureSlot = 99;
	static constexpr uint32_t kWaterSlot = 101;  // t100 is Grass Collision's

	/** @brief Per-geometry constants for Lighting.hlsl (skinFlowParams, skinFlowLook in Skin.hlsli). */
	struct Params
	{
		float4 params;  ///< x = 1 when a surface is bound, y = SkinFlowView, z = sweat amount, w = world units per UV unit
		float4 look;    ///< x = drop size, y = sheen
		bool operator==(const Params&) const = default;
	};

	/**
	 * @brief Asks the provider for this pass's surface and binds it.
	 * @return all zero when the pass is not SkinFlow's.
	 */
	Params Bind(ID3D11DeviceContext* a_context, RE::BSRenderPass* a_pass);

	/** @brief True when SkinFlow.dll is loaded with a matching API. */
	bool Available();

private:
	void Resolve();

	bool resolved = false;
	SkinFlow_GetSurface_t getSurface = nullptr;
};

/**
 * @brief Recompiles the Lighting shaders while the game runs when Shaders\Lighting.hlsl changes.
 *
 * For iterating on SkinFlow's sweat shading without restarts. SkinFlow's installer stamps
 * Lighting.hlsl on any shader change (Skin.hlsli included), which also marks the disk cache stale
 * when "Skip Unchanged Shaders" is on; CS's own file watcher does not see files under MO2's VFS.
 */
class SkinFlowShaderWatch
{
public:
	/** @brief Call once a frame; checks the file once a second. */
	void Poll();

private:
	std::chrono::steady_clock::time_point nextCheck{};
	std::filesystem::file_time_type lightingTime{};
	bool known = false;
	bool warnedDiskCache = false;
};
