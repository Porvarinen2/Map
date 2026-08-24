package fi.tesles.seasons.mixin.fix061.client;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"fi.tesles.seasons.client.voxy.VoxySeasonShaderPatch"},
   remap = false
)
public abstract class VoxySeasonShaderSafetyFixMixin {
   @Unique
   private static final String ORGANIC_GROUND_NOISE = "float teslesGroundNoise(vec3 worldPos) {\n    vec2 p = floor(worldPos.xz);\n\n    float warpX = (teslesValueNoise(p, 73.0, 0x6A09E667u) - 0.5) * 28.0\n                + (teslesValueNoise(p, 31.0, 0x510E527Fu) - 0.5) * 10.0;\n    float warpZ = (teslesValueNoise(p, 79.0, 0xBB67AE85u) - 0.5) * 28.0\n                + (teslesValueNoise(p, 29.0, 0x9B05688Cu) - 0.5) * 10.0;\n\n    vec2 warped = p + vec2(warpX, warpZ);\n    float broad = teslesValueNoise(warped, 59.0, 0x3C6EF372u);\n    float medium = teslesValueNoise(warped, 23.0, 0xA54FF53Au);\n    float fine = teslesValueNoise(warped, 11.0, 0x1F83D9ABu);\n    float micro = teslesValueNoise(p, 5.0, 0x5BE0CD19u);\n    ivec2 blockCell = ivec2(p);\n    float jitter = teslesCellNoise(blockCell, 0xC2B2AE35u);\n    float raw = broad * 0.50 + medium * 0.25 + fine * 0.14 + micro * 0.05 + jitter * 0.06;\n    return clamp(1.0 / (1.0 + exp(-(raw - 0.5) * 12.0)), 0.0, 1.0);\n}\n";
   @Unique
   private static final String SHARED_SNOW_MASK = "float teslesSnowMask(vec3 worldPos) {\n    // Same realtime season channel as leafRetention. The physical near field and Voxy use the same\n    // deterministic spatial field; Voxy does not wait for or rewrite distant chunks.\n    if (teslesSnowCover <= 0.005) return 0.0;\n    if (teslesSnowCover >= 0.995) return 1.0;\n    float n = teslesGroundNoise(worldPos);\n    float threshold = clamp(teslesSnowCover, 0.0, 1.0);\n    return 1.0 - smoothstep(threshold - 0.010, threshold + 0.010, n);\n}\n";
   @Unique
   private static final String SAFE_TERRAIN_SNOW = "vec3 teslesApplyTerrainSnow(vec3 rgb, uint category, uint physicalFace, vec3 worldPos) {\n    if (teslesSnowCover <= 0.005 || teslesSnowDepth <= 0.0001) return rgb;\n\n    float snow = teslesSnowMask(worldPos);\n    if (snow <= 0.001) return rgb;\n    float farBlend = teslesVoxyDistanceBlend(worldPos);\n\n    // Voxy always keeps neutral terrain topology. Natural top faces are recoloured in realtime;\n    // thickness is represented on side faces from the same 1/8..8/8 depth channel as Minecraft.\n    if ((category == 4u || category == 6u) && physicalFace == 1u) {\n        #ifndef PATCHED_SHADER\n        // With an external shader pack disabled Voxy's rgb already contains its baked lighting.\n        // 0.6.9 replaced ~99% of that signal with flat white, which destroyed texture/light detail\n        // and made distant terrain look like a featureless white sheet. Keep the underlying\n        // luminance and add deterministic snow grain so the standard Voxy pipeline is useful too.\n        float lum = clamp(dot(rgb, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);\n        float grain = (teslesValueNoise(floor(worldPos.xz), 3.0, 0xD2511F53u) - 0.5) * 0.055;\n        float detail = clamp((lum - 0.56) * 0.20, -0.055, 0.070);\n        vec3 snowRgb = clamp(vec3(0.90, 0.925, 0.95) + vec3(detail + grain), vec3(0.76), vec3(0.985));\n        float strength = snow * mix(0.80, 0.87, farBlend);\n        return mix(rgb, snowRgb, clamp(strength, 0.0, 0.90));\n        #else\n        float strength = snow * mix(0.95, 0.99, farBlend);\n        return mix(rgb, teslesSnowTopColour(rgb, farBlend), clamp(strength, 0.0, 0.99));\n        #endif\n    }\n\n    if (category == 4u && physicalFace >= 2u) {\n        float lodScale = exp2(float(teslesVoxyLodLevel));\n        float capFraction = clamp(teslesSnowDepth / max(1.0, lodScale), 0.0, 1.0);\n        float withinCellY = fract((worldPos.y + 0.0005) / max(1.0, lodScale));\n        float cap = smoothstep(1.0 - capFraction - 0.018,\n                               1.0 - capFraction + 0.018, withinCellY);\n        #ifndef PATCHED_SHADER\n        float sideStrength = snow * cap * mix(0.42, 0.58, farBlend);\n        vec3 sideSnow = teslesSnowSideColour(rgb, farBlend) * 0.88;\n        return mix(rgb, sideSnow, clamp(sideStrength, 0.0, 0.62));\n        #else\n        float sideStrength = snow * cap * mix(0.58, 0.76, farBlend);\n        return mix(rgb, teslesSnowSideColour(rgb, farBlend), clamp(sideStrength, 0.0, 0.78));\n        #endif\n    }\n    if (category == 6u && physicalFace >= 2u) {\n        float lodScale = exp2(float(teslesVoxyLodLevel));\n        float capFraction = clamp(teslesSnowDepth / max(1.0, lodScale), 0.0, 1.0);\n        float withinCellY = fract((worldPos.y + 0.0005) / max(1.0, lodScale));\n        float cap = smoothstep(1.0 - capFraction - 0.018,\n                               1.0 - capFraction + 0.018, withinCellY);\n        float substrateStrength = snow * cap * farBlend * 0.28;\n        return mix(rgb, teslesSnowSideColour(rgb, farBlend), clamp(substrateStrength, 0.0, 0.28));\n    }\n\n    return rgb;\n}\n";
   @Unique
   private static final String SAFE_SEASON_COLOUR = "vec3 teslesSeasonColour(vec3 rgb, uint category, uint physicalFace, vec3 worldPos) {\n    if (category == 1u) {\n        rgb = mix(rgb, vec3(0.61, 0.43, 0.21), clamp(teslesAutumn * 0.80, 0.0, 0.80));\n        rgb = mix(rgb, vec3(0.51, 0.45, 0.33), clamp(teslesDormancy * 0.16, 0.0, 0.20));\n        rgb = mix(rgb, vec3(0.43, 0.64, 0.34), clamp(teslesSpringFresh * 0.12, 0.0, 0.14));\n    } else if (category == 2u) {\n        rgb = mix(rgb, vec3(0.57, 0.50, 0.28), clamp(teslesAutumn * 0.28, 0.0, 0.32));\n        rgb = mix(rgb, vec3(0.62, 0.58, 0.43), clamp(teslesDormancy * 0.38, 0.0, 0.42));\n        rgb = mix(rgb, vec3(0.50, 0.67, 0.36), clamp(teslesSpringFresh * 0.10, 0.0, 0.12));\n    } else if (category == 3u) {\n        float gray = dot(rgb, vec3(0.299, 0.587, 0.114));\n        rgb = mix(rgb, vec3(gray) * vec3(0.92, 0.98, 0.90), clamp(teslesDormancy * 0.12, 0.0, 0.14));\n        if (physicalFace == 1u && teslesSnowCover > 0.05) {\n            float coniferSnow = teslesSnowMask(worldPos) * clamp(teslesSnowDepth * 0.34, 0.0, 0.34);\n            rgb = mix(rgb, teslesSnowTopColour(rgb, teslesVoxyDistanceBlend(worldPos)), coniferSnow);\n        }\n    } else if (category == 4u) {\n        // Grass stays grass: preserve the baked grass texture/biome colour and only add a restrained\n        // olive/frost tint. Never push seasonal ground toward a dirt-brown replacement colour.\n        rgb = mix(rgb, vec3(0.51, 0.59, 0.37), clamp(teslesAutumn * 0.08, 0.0, 0.09));\n        rgb = mix(rgb, vec3(0.67, 0.72, 0.61), clamp(teslesDormancy * 0.15, 0.0, 0.17));\n    } else if (category == 5u) {\n        rgb = mix(rgb, vec3(0.72, 0.65, 0.49), clamp(teslesDormancy * 0.22, 0.0, 0.24));\n        rgb = mix(rgb, vec3(0.72, 0.62, 0.39), clamp(teslesAutumn * 0.13, 0.0, 0.15));\n    } else if (category == 7u) {\n        rgb = mix(rgb, vec3(0.90, 0.91, 0.90), clamp(teslesSnowDepth * 0.12, 0.0, 0.14));\n    } else if (category == 8u) {\n        rgb = mix(rgb, vec3(0.58, 0.50, 0.38), clamp(teslesDormancy * 0.12, 0.0, 0.14));\n    } else if (category == 9u) {\n        rgb = mix(rgb, vec3(0.64, 0.61, 0.50), clamp(teslesDormancy * 0.10, 0.0, 0.12));\n    } else if (category == 10u) {\n        // A temporary/stale snow mesh must stay visibly snow until its neutral remesh arrives. The\n        // old fallback recoloured lingering SnowLayerBlock geometry green/brown during spring,\n        // producing the raised \"playdoh grass\" strips. Never pretend snow geometry is ground.\n        rgb = mix(rgb, vec3(0.93, 0.94, 0.95), 0.18);\n    }\n    return teslesApplyTerrainSnow(rgb, category, physicalFace, worldPos);\n}\n";
   @Unique
   private static final String OLD_IRIS_SEASON_BLOCK = "uint face = getFace();\nuint teslesPhysicalFace = face;\nif (doTint) {\n    tint.rgb = teslesSeasonColour(tint.rgb, teslesSeasonCategory, teslesPhysicalFace, teslesWorldPos);\n} else {\n    colour.rgb = teslesSeasonColour(colour.rgb, teslesSeasonCategory, teslesPhysicalFace, teslesWorldPos);\n}\nface ^= uint((face&1u)!=uint(gl_FrontFacing!=((face>>1)!=0u)));\nvoxy_emitFragment(VoxyFragmentParameters(colour, tile, texPos, face, modelId, getLightmapUv(interData.y), tint, teslesOriginalCustomId(model.customId)));\n";
   @Unique
   private static final String FINAL_RGB_IRIS_SEASON_BLOCK = "uint face = getFace();\nuint teslesPhysicalFace = face;\n// Iris/Voxy keeps the sampled texture and biome tint as separate values. Fold them together first\n// so a snow operation changes the actual final surface colour instead of merely changing the tint\n// multiplier. Leaves can be recoloured either way; a white snow blanket cannot.\nvec3 teslesFinalRgb = colour.rgb;\nif (doTint) {\n    teslesFinalRgb *= tint.rgb;\n    tint.rgb = vec3(1.0);\n}\ncolour.rgb = teslesSeasonColour(teslesFinalRgb, teslesSeasonCategory, teslesPhysicalFace, teslesWorldPos);\nface ^= uint((face&1u)!=uint(gl_FrontFacing!=((face>>1)!=0u)));\nvoxy_emitFragment(VoxyFragmentParameters(colour, tile, texPos, face, modelId, getLightmapUv(interData.y), tint, teslesOriginalCustomId(model.customId)));\n";

   @Inject(
      method = {"patch(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;"},
      at = {@At("RETURN")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$fixVoxyShader(String resource, String source, CallbackInfoReturnable<String> cir) {
      String out = (String)cir.getReturnValue();
      if (out != null && !out.isEmpty()) {
         if ("voxy:lod/gl46/quads3.vert".equals(resource)) {
            out = out.replace(
               "layout(location = 6) out vec3 teslesWorldPos;\nuniform int teslesVisualSeed;",
               "layout(location = 6) out vec3 teslesWorldPos;\nlayout(location = 8) out flat uint teslesVoxyLodLevel;\nuniform int teslesVisualSeed;"
            );
            out = out.replace(
               "teslesWorldPos = teslesRelativePos + vec3(baseSectionPos << 5);",
               "teslesWorldPos = teslesRelativePos + vec3(baseSectionPos << 5);\n    teslesVoxyLodLevel = getLoDLevel(pos);"
            );
            cir.setReturnValue(out);
         } else if ("voxy:lod/gl46/quads.frag".equals(resource)) {
            out = out.replace(
               "layout(location = 6) in vec3 teslesWorldPos;\nuniform float teslesAutumn;",
               "layout(location = 6) in vec3 teslesWorldPos;\nlayout(location = 8) in flat uint teslesVoxyLodLevel;\nuniform float teslesAutumn;"
            );
            out = out.replace(
               "uniform float teslesSnowCover;", "uniform float teslesSnowCover;\nuniform float teslesSnowDepth;\nuniform float teslesPlantRetention;"
            );
            out = removeSeasonDiscardBlock(out);
            out = replaceFunction(
               out,
               "float teslesGroundNoise(",
               "float teslesGroundNoise(vec3 worldPos) {\n    vec2 p = floor(worldPos.xz);\n\n    float warpX = (teslesValueNoise(p, 73.0, 0x6A09E667u) - 0.5) * 28.0\n                + (teslesValueNoise(p, 31.0, 0x510E527Fu) - 0.5) * 10.0;\n    float warpZ = (teslesValueNoise(p, 79.0, 0xBB67AE85u) - 0.5) * 28.0\n                + (teslesValueNoise(p, 29.0, 0x9B05688Cu) - 0.5) * 10.0;\n\n    vec2 warped = p + vec2(warpX, warpZ);\n    float broad = teslesValueNoise(warped, 59.0, 0x3C6EF372u);\n    float medium = teslesValueNoise(warped, 23.0, 0xA54FF53Au);\n    float fine = teslesValueNoise(warped, 11.0, 0x1F83D9ABu);\n    float micro = teslesValueNoise(p, 5.0, 0x5BE0CD19u);\n    ivec2 blockCell = ivec2(p);\n    float jitter = teslesCellNoise(blockCell, 0xC2B2AE35u);\n    float raw = broad * 0.50 + medium * 0.25 + fine * 0.14 + micro * 0.05 + jitter * 0.06;\n    return clamp(1.0 / (1.0 + exp(-(raw - 0.5) * 12.0)), 0.0, 1.0);\n}\n"
            );
            out = replaceFunction(
               out,
               "float teslesSnowMask(",
               "float teslesSnowMask(vec3 worldPos) {\n    // Same realtime season channel as leafRetention. The physical near field and Voxy use the same\n    // deterministic spatial field; Voxy does not wait for or rewrite distant chunks.\n    if (teslesSnowCover <= 0.005) return 0.0;\n    if (teslesSnowCover >= 0.995) return 1.0;\n    float n = teslesGroundNoise(worldPos);\n    float threshold = clamp(teslesSnowCover, 0.0, 1.0);\n    return 1.0 - smoothstep(threshold - 0.010, threshold + 0.010, n);\n}\n"
            );
            out = replaceFunction(
               out,
               "vec3 teslesApplyTerrainSnow(",
               "vec3 teslesApplyTerrainSnow(vec3 rgb, uint category, uint physicalFace, vec3 worldPos) {\n    if (teslesSnowCover <= 0.005 || teslesSnowDepth <= 0.0001) return rgb;\n\n    float snow = teslesSnowMask(worldPos);\n    if (snow <= 0.001) return rgb;\n    float farBlend = teslesVoxyDistanceBlend(worldPos);\n\n    // Voxy always keeps neutral terrain topology. Natural top faces are recoloured in realtime;\n    // thickness is represented on side faces from the same 1/8..8/8 depth channel as Minecraft.\n    if ((category == 4u || category == 6u) && physicalFace == 1u) {\n        #ifndef PATCHED_SHADER\n        // With an external shader pack disabled Voxy's rgb already contains its baked lighting.\n        // 0.6.9 replaced ~99% of that signal with flat white, which destroyed texture/light detail\n        // and made distant terrain look like a featureless white sheet. Keep the underlying\n        // luminance and add deterministic snow grain so the standard Voxy pipeline is useful too.\n        float lum = clamp(dot(rgb, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);\n        float grain = (teslesValueNoise(floor(worldPos.xz), 3.0, 0xD2511F53u) - 0.5) * 0.055;\n        float detail = clamp((lum - 0.56) * 0.20, -0.055, 0.070);\n        vec3 snowRgb = clamp(vec3(0.90, 0.925, 0.95) + vec3(detail + grain), vec3(0.76), vec3(0.985));\n        float strength = snow * mix(0.80, 0.87, farBlend);\n        return mix(rgb, snowRgb, clamp(strength, 0.0, 0.90));\n        #else\n        float strength = snow * mix(0.95, 0.99, farBlend);\n        return mix(rgb, teslesSnowTopColour(rgb, farBlend), clamp(strength, 0.0, 0.99));\n        #endif\n    }\n\n    if (category == 4u && physicalFace >= 2u) {\n        float lodScale = exp2(float(teslesVoxyLodLevel));\n        float capFraction = clamp(teslesSnowDepth / max(1.0, lodScale), 0.0, 1.0);\n        float withinCellY = fract((worldPos.y + 0.0005) / max(1.0, lodScale));\n        float cap = smoothstep(1.0 - capFraction - 0.018,\n                               1.0 - capFraction + 0.018, withinCellY);\n        #ifndef PATCHED_SHADER\n        float sideStrength = snow * cap * mix(0.42, 0.58, farBlend);\n        vec3 sideSnow = teslesSnowSideColour(rgb, farBlend) * 0.88;\n        return mix(rgb, sideSnow, clamp(sideStrength, 0.0, 0.62));\n        #else\n        float sideStrength = snow * cap * mix(0.58, 0.76, farBlend);\n        return mix(rgb, teslesSnowSideColour(rgb, farBlend), clamp(sideStrength, 0.0, 0.78));\n        #endif\n    }\n    if (category == 6u && physicalFace >= 2u) {\n        float lodScale = exp2(float(teslesVoxyLodLevel));\n        float capFraction = clamp(teslesSnowDepth / max(1.0, lodScale), 0.0, 1.0);\n        float withinCellY = fract((worldPos.y + 0.0005) / max(1.0, lodScale));\n        float cap = smoothstep(1.0 - capFraction - 0.018,\n                               1.0 - capFraction + 0.018, withinCellY);\n        float substrateStrength = snow * cap * farBlend * 0.28;\n        return mix(rgb, teslesSnowSideColour(rgb, farBlend), clamp(substrateStrength, 0.0, 0.28));\n    }\n\n    return rgb;\n}\n"
            );
            out = replaceFunction(
               out,
               "vec3 teslesSeasonColour(",
               "vec3 teslesSeasonColour(vec3 rgb, uint category, uint physicalFace, vec3 worldPos) {\n    if (category == 1u) {\n        rgb = mix(rgb, vec3(0.61, 0.43, 0.21), clamp(teslesAutumn * 0.80, 0.0, 0.80));\n        rgb = mix(rgb, vec3(0.51, 0.45, 0.33), clamp(teslesDormancy * 0.16, 0.0, 0.20));\n        rgb = mix(rgb, vec3(0.43, 0.64, 0.34), clamp(teslesSpringFresh * 0.12, 0.0, 0.14));\n    } else if (category == 2u) {\n        rgb = mix(rgb, vec3(0.57, 0.50, 0.28), clamp(teslesAutumn * 0.28, 0.0, 0.32));\n        rgb = mix(rgb, vec3(0.62, 0.58, 0.43), clamp(teslesDormancy * 0.38, 0.0, 0.42));\n        rgb = mix(rgb, vec3(0.50, 0.67, 0.36), clamp(teslesSpringFresh * 0.10, 0.0, 0.12));\n    } else if (category == 3u) {\n        float gray = dot(rgb, vec3(0.299, 0.587, 0.114));\n        rgb = mix(rgb, vec3(gray) * vec3(0.92, 0.98, 0.90), clamp(teslesDormancy * 0.12, 0.0, 0.14));\n        if (physicalFace == 1u && teslesSnowCover > 0.05) {\n            float coniferSnow = teslesSnowMask(worldPos) * clamp(teslesSnowDepth * 0.34, 0.0, 0.34);\n            rgb = mix(rgb, teslesSnowTopColour(rgb, teslesVoxyDistanceBlend(worldPos)), coniferSnow);\n        }\n    } else if (category == 4u) {\n        // Grass stays grass: preserve the baked grass texture/biome colour and only add a restrained\n        // olive/frost tint. Never push seasonal ground toward a dirt-brown replacement colour.\n        rgb = mix(rgb, vec3(0.51, 0.59, 0.37), clamp(teslesAutumn * 0.08, 0.0, 0.09));\n        rgb = mix(rgb, vec3(0.67, 0.72, 0.61), clamp(teslesDormancy * 0.15, 0.0, 0.17));\n    } else if (category == 5u) {\n        rgb = mix(rgb, vec3(0.72, 0.65, 0.49), clamp(teslesDormancy * 0.22, 0.0, 0.24));\n        rgb = mix(rgb, vec3(0.72, 0.62, 0.39), clamp(teslesAutumn * 0.13, 0.0, 0.15));\n    } else if (category == 7u) {\n        rgb = mix(rgb, vec3(0.90, 0.91, 0.90), clamp(teslesSnowDepth * 0.12, 0.0, 0.14));\n    } else if (category == 8u) {\n        rgb = mix(rgb, vec3(0.58, 0.50, 0.38), clamp(teslesDormancy * 0.12, 0.0, 0.14));\n    } else if (category == 9u) {\n        rgb = mix(rgb, vec3(0.64, 0.61, 0.50), clamp(teslesDormancy * 0.10, 0.0, 0.12));\n    } else if (category == 10u) {\n        // A temporary/stale snow mesh must stay visibly snow until its neutral remesh arrives. The\n        // old fallback recoloured lingering SnowLayerBlock geometry green/brown during spring,\n        // producing the raised \"playdoh grass\" strips. Never pretend snow geometry is ground.\n        rgb = mix(rgb, vec3(0.93, 0.94, 0.95), 0.18);\n    }\n    return teslesApplyTerrainSnow(rgb, category, physicalFace, worldPos);\n}\n"
            );
            out = out.replace(
               "uint face = getFace();\nuint teslesPhysicalFace = face;\nif (doTint) {\n    tint.rgb = teslesSeasonColour(tint.rgb, teslesSeasonCategory, teslesPhysicalFace, teslesWorldPos);\n} else {\n    colour.rgb = teslesSeasonColour(colour.rgb, teslesSeasonCategory, teslesPhysicalFace, teslesWorldPos);\n}\nface ^= uint((face&1u)!=uint(gl_FrontFacing!=((face>>1)!=0u)));\nvoxy_emitFragment(VoxyFragmentParameters(colour, tile, texPos, face, modelId, getLightmapUv(interData.y), tint, teslesOriginalCustomId(model.customId)));\n",
               "uint face = getFace();\nuint teslesPhysicalFace = face;\n// Iris/Voxy keeps the sampled texture and biome tint as separate values. Fold them together first\n// so a snow operation changes the actual final surface colour instead of merely changing the tint\n// multiplier. Leaves can be recoloured either way; a white snow blanket cannot.\nvec3 teslesFinalRgb = colour.rgb;\nif (doTint) {\n    teslesFinalRgb *= tint.rgb;\n    tint.rgb = vec3(1.0);\n}\ncolour.rgb = teslesSeasonColour(teslesFinalRgb, teslesSeasonCategory, teslesPhysicalFace, teslesWorldPos);\nface ^= uint((face&1u)!=uint(gl_FrontFacing!=((face>>1)!=0u)));\nvoxy_emitFragment(VoxyFragmentParameters(colour, tile, texPos, face, modelId, getLightmapUv(interData.y), tint, teslesOriginalCustomId(model.customId)));\n"
            );
            cir.setReturnValue(out);
         }
      }
   }

   @Unique
   private static String removeSeasonDiscardBlock(String source) {
      String startToken = "\nfloat teslesBlockNoise = teslesHash01(teslesBlockHash(teslesWorldPos, getFace()));";
      int start = source.indexOf(startToken);
      if (start < 0) {
         return source;
      } else {
         int end = source.indexOf("\n#ifndef PATCHED_SHADER", start);
         if (end < 0) {
            return source;
         } else {
            String safeVisibility = "\nfloat teslesVisibilityNoise = teslesHash01(teslesBlockHash(teslesWorldPos, getFace()));\n\n// Deciduous leaves are Voxy proxy geometry: percentage is literal leaf retention everywhere.\nif (teslesSeasonCategory == 1u && teslesLeafRetention < 0.999 &&\n        (teslesLeafRetention <= 0.001 || teslesVisibilityNoise > teslesLeafRetention)) {\n    discard;\n    return;\n}\n\n// Wild flora is also proxy geometry. Where current snow covers the cell, hide the plant and let the\n// still-present neutral ground underneath render as snow. No terrain voxel is ever deleted.\nif (teslesSeasonCategory == 2u || teslesSeasonCategory == 5u ||\n    teslesSeasonCategory == 8u || teslesSeasonCategory == 9u) {\n    if (teslesSnowCover > 0.005 && teslesSnowDepth > 0.0001 && teslesSnowMask(teslesWorldPos) > 0.50) {\n        discard;\n        return;\n    }\n\n    if ((teslesSeasonCategory == 2u || teslesSeasonCategory == 9u) &&\n            teslesPlantRetention < 0.999 &&\n            (teslesPlantRetention <= 0.001 || teslesVisibilityNoise > teslesPlantRetention)) {\n        discard;\n        return;\n    }\n    if (teslesSeasonCategory == 5u && teslesFlowerRetention < 0.999 &&\n            (teslesFlowerRetention <= 0.001 || teslesVisibilityNoise > teslesFlowerRetention)) {\n        discard;\n        return;\n    }\n    if (teslesSeasonCategory == 8u && teslesMushroomRetention < 0.999 &&\n            (teslesMushroomRetention <= 0.001 || teslesVisibilityNoise > teslesMushroomRetention)) {\n        discard;\n        return;\n    }\n}\n";
            return source.substring(0, start) + safeVisibility + source.substring(end);
         }
      }
   }

   @Unique
   private static String replaceFunction(String source, String signatureStart, String replacement) {
      int start = source.indexOf(signatureStart);
      if (start < 0) {
         return source;
      } else {
         int open = source.indexOf(123, start);
         if (open < 0) {
            return source;
         } else {
            int depth = 0;

            for (int i = open; i < source.length(); i++) {
               char c = source.charAt(i);
               if (c == '{') {
                  depth++;
               } else if (c == '}') {
                  if (--depth == 0) {
                     int end = i + 1;
                     return source.substring(0, start) + replacement + source.substring(end);
                  }
               }
            }

            return source;
         }
      }
   }
}
