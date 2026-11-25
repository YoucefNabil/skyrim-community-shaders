#include "SkinFlowBridge.h"

#include "Globals.h"
#include "ShaderCache.h"

void SkinFlowBridge::Resolve()
{
	resolved = true;
	const HMODULE module = GetModuleHandleW(L"SkinFlow.dll");
	if (!module) {
		logger::info("[Advanced Skin] SkinFlow.dll not loaded, built-in wetness only");
		return;
	}
	const auto getVersion = reinterpret_cast<SkinFlow_GetApiVersion_t>(GetProcAddress(module, "SkinFlow_GetApiVersion"));
	const uint32_t version = getVersion ? getVersion() : 0;
	if (version != SKINFLOW_API_VERSION) {
		logger::warn("[Advanced Skin] SkinFlow.dll API version {} (expected {}), ignored", version, SKINFLOW_API_VERSION);
		return;
	}
	getSurface = reinterpret_cast<SkinFlow_GetSurface_t>(GetProcAddress(module, "SkinFlow_GetSurface"));
	logger::info("[Advanced Skin] SkinFlow.dll API {} found", version);
}

bool SkinFlowBridge::Available()
{
	if (!resolved) {
		Resolve();
	}
	return getSurface != nullptr;
}

SkinFlowBridge::Params SkinFlowBridge::Bind(ID3D11DeviceContext* a_context, RE::BSRenderPass* a_pass)
{
	if (!resolved) {
		Resolve();
	}
	SkinFlowSurface surface{};
	if (!getSurface || !getSurface(a_pass, &surface) || !surface.srv || !surface.water) {
		return {};
	}
	a_context->PSSetShaderResources(kTextureSlot, 1, &surface.srv);
	a_context->PSSetShaderResources(kWaterSlot, 1, &surface.water);
	return {
		float4(1.0f, static_cast<float>(surface.view), surface.amount, surface.uvScale),
		float4(surface.look.dropSize, surface.look.sheen, 0.0f, 0.0f)
	};
}

void SkinFlowShaderWatch::Poll()
{
	const auto now = std::chrono::steady_clock::now();
	if (now < nextCheck) {
		return;
	}
	nextCheck = now + std::chrono::seconds(1);

	std::error_code error;
	const auto time = std::filesystem::last_write_time(L"Data\\Shaders\\Lighting.hlsl", error);
	if (error) {
		return;
	}
	if (!known || time == lightingTime) {
		known = true;
		lightingTime = time;
		return;
	}
	lightingTime = time;

	auto* cache = globals::shaderCache;
	if (cache->IsDiskCache() && !cache->IsSkipUnchangedShaders() && !warnedDiskCache) {
		warnedDiskCache = true;
		logger::warn("[Advanced Skin] Lighting.hlsl changed, but the disk cache is on without Skip Unchanged Shaders: old shaders may come back from disk");
	}
	logger::info("[Advanced Skin] Lighting.hlsl changed: recompiling the Lighting shaders");
	cache->Clear(RE::BSShader::Type::Lighting);
}
