package fi.tesles.seasons.client.voxy;

import fi.tesles.seasons.TeslesSeasons;

public final class VoxySeasonShaderPatch {
   private static final String VERTEX = "voxy:lod/gl46/quads3.vert";
   private static final String FRAGMENT = "voxy:lod/gl46/quads.frag";
   private static boolean vertexLogged;
   private static boolean fragmentLogged;
   private static boolean vertexWarned;
   private static boolean fragmentWarned;

   private VoxySeasonShaderPatch() {
   }

   public static String patch(String resource, String source) {
      if (TeslesSeasons.CONFIG == null || !TeslesSeasons.CONFIG.voxySeasonRendering || resource == null || source == null) {
         return source;
      } else if (resource.equals("voxy:lod/gl46/quads3.vert")) {
         return patchVertex(source);
      } else {
         return resource.equals("voxy:lod/gl46/quads.frag") ? patchFragment(source) : source;
      }
   }

   private static String patchVertex(String source) {
      if (source.contains("teslesSeasonCategory")) {
         return source;
      } else {
         String ioAnchor = "#ifndef USE_NV_BARRY\nlayout(location = 1) out vec2 uv;\n#endif";
         String dataAnchor = "    interData = quad.attributeData;";
         if (source.contains(ioAnchor) && source.contains(dataAnchor)) {
            String io = ioAnchor
               + "\nlayout(location = 5) out flat uint teslesSeasonCategory;\nlayout(location = 6) out vec3 teslesWorldPos;\nuniform int teslesVisualSeed;\n";
            String data = dataAnchor
               + "\n    uint teslesModelId = extractStateId(quadData[uint(gl_VertexID)>>2]);\n    uint teslesRawCustomId = modelData[teslesModelId].customId;\n    // 0.5.x format: 01 marker in the top two bits, 4-bit category, 26-bit original id.\n    if ((teslesRawCustomId & 0xC0000000u) == 0x40000000u) {\n        teslesSeasonCategory = (teslesRawCustomId >> 26u) & 0x0Fu;\n    } else {\n        // Backward compatibility with 0.4.x cached model ids (0xA? high byte).\n        uint teslesOldTag = teslesRawCustomId >> 24u;\n        teslesSeasonCategory = ((teslesOldTag & 0xF0u) == 0xA0u) ? (teslesOldTag & 0x0Fu) : 0u;\n    }\n    vec2 teslesCornerMask = vec2((cornerId>>1)&1u, cornerId&1u) * quad.lodScale;\n    vec3 teslesRelativePos = quad.basePoint + swizzelDataAxis(quad.axis, vec3(quad.quadSizeAddin * teslesCornerMask, 0));\n    teslesWorldPos = teslesRelativePos + vec3(baseSectionPos << 5);\n";
            String patched = source.replace(ioAnchor, io).replace(dataAnchor, data);
            VoxyShaderDiagnostics.markVertexPatched();
            if (!vertexLogged) {
               vertexLogged = true;
               TeslesSeasons.LOGGER.info("TESLES Voxy 0.2.18-beta vertex season bridge applied (26-bit Iris-safe seasonal ids).");
            }

            return patched;
         } else {
            if (!vertexWarned) {
               vertexWarned = true;
               TeslesSeasons.LOGGER.warn("Voxy vertex shader layout differs from 0.2.18-beta; TESLES seasonal LOD bridge skipped safely.");
            }

            return source;
         }
      }
   }

   private static String patchFragment(String source) {
      if (source.contains("teslesLeafRetention")) {
         return source;
      } else {
         String ioAnchor = "#ifndef USE_NV_BARRY\nlayout(location = 1) in vec2 uv;\n#endif";
         String functionAnchor = "uint getModelId() {\n    return interData.x>>16;\n}";
         String nonPatchedAnchor = "    colour = computeColour(texPos, colour);\n    outColour = colour;";
         String patchedFaceAnchor = "    uint face = getFace();\n    face ^= uint((face&1u)!=uint(gl_FrontFacing!=((face>>1)!=0u)));\n    voxy_emitFragment(VoxyFragmentParameters(colour, tile, texPos, face, modelId, getLightmapUv(interData.y), tint, model.customId));";
         String alphaAnchor = "    #ifndef PATCHED_SHADER_ALLOW_DERIVATIVES\n    if (gl_HelperInvocation) {\n        return;\n    }\n    #endif\n\n    #ifndef PATCHED_SHADER";
         if (source.contains(ioAnchor)
            && source.contains(functionAnchor)
            && source.contains(nonPatchedAnchor)
            && source.contains(patchedFaceAnchor)
            && source.contains(alphaAnchor)) {
            String io = ioAnchor
               + "\nlayout(location = 5) in flat uint teslesSeasonCategory;\nlayout(location = 6) in vec3 teslesWorldPos;\nuniform float teslesAutumn;\nuniform float teslesDormancy;\nuniform float teslesLeafRetention;\nuniform float teslesFlowerRetention;\nuniform float teslesMushroomRetention;\nuniform float teslesSnowCover;\nuniform float teslesSpringFresh;\nuniform float teslesVoxyBlendStart;\nuniform float teslesVoxyBlendEnd;\nuniform int teslesVisualSeed;\n";
            String functions = functionAnchor
               + "\nfloat teslesHash01(uint h) {\n    h ^= h >> 16;\n    h *= 0x7FEB352Du;\n    h ^= h >> 15;\n    h *= 0x846CA68Bu;\n    h ^= h >> 16;\n    return float(h & 0x00FFFFFFu) / 16777215.0;\n}\n\nfloat teslesCellNoise(ivec2 cell, uint salt) {\n    uint h = uint(cell.x) * 0x9E3779B9u ^ uint(cell.y) * 0x85EBCA6Bu ^ uint(teslesVisualSeed) ^ salt;\n    return teslesHash01(h);\n}\n\nfloat teslesValueNoise(vec2 p, float scale, uint salt) {\n    vec2 q = p / scale;\n    ivec2 cell = ivec2(floor(q));\n    vec2 f = fract(q);\n    f = f * f * (3.0 - 2.0 * f);\n    float n00 = teslesCellNoise(cell, salt);\n    float n10 = teslesCellNoise(cell + ivec2(1, 0), salt);\n    float n01 = teslesCellNoise(cell + ivec2(0, 1), salt);\n    float n11 = teslesCellNoise(cell + ivec2(1, 1), salt);\n    return mix(mix(n00, n10, f.x), mix(n01, n11, f.x), f.y);\n}\n\nfloat teslesGroundNoise(vec3 worldPos) {\n    vec2 p = worldPos.xz;\n    float broad = teslesValueNoise(p, 41.0, 0x6A09E667u);\n    float medium = teslesValueNoise(p, 17.0, 0xBB67AE85u);\n    float fine = teslesValueNoise(p, 7.0, 0x3C6EF372u);\n    ivec2 blockCell = ivec2(floor(p));\n    float jitter = teslesCellNoise(blockCell, 0xA54FF53Au);\n    return clamp(broad * 0.50 + medium * 0.28 + fine * 0.16 + jitter * 0.06, 0.0, 1.0);\n}\n\nfloat teslesVoxyDistanceBlend(vec3 worldPos) {\n    vec3 cameraWorld = vec3(baseSectionPos << 5) + cameraSubPos;\n    float distanceXZ = length(worldPos.xz - cameraWorld.xz);\n    float startDistance = max(0.0, teslesVoxyBlendStart);\n    float endDistance = max(startDistance + 1.0, teslesVoxyBlendEnd);\n    return smoothstep(startDistance, endDistance, distanceXZ);\n}\n\nfloat teslesSnowMask(vec3 worldPos) {\n    if (teslesSnowCover <= 0.005) return 0.0;\n    if (teslesSnowCover >= 0.82) return 1.0;\n    float n = teslesGroundNoise(worldPos);\n    float threshold = clamp(teslesSnowCover, 0.0, 1.0);\n    float mask = 1.0 - smoothstep(threshold - 0.090, threshold + 0.055, n);\n    return mask * smoothstep(0.01, 0.10, teslesSnowCover);\n}\n\nvec3 teslesSnowTopColour(vec3 source, float farBlend) {\n    float luminance = clamp(dot(source, vec3(0.299, 0.587, 0.114)), 0.20, 1.0);\n    vec3 coolSnow = vec3(0.982, 0.990, 1.000);\n    // The physical near field is already a bright snow material. Far Voxy must converge toward that\n    // same white value instead of retaining the underlying grass/dirt luminance as a grey blanket.\n    float lighting = mix(0.94 + luminance * 0.06, 0.975 + luminance * 0.025, farBlend);\n    return coolSnow * lighting;\n}\n\nvec3 teslesSnowSideColour(vec3 source, float farBlend) {\n    float luminance = clamp(dot(source, vec3(0.299, 0.587, 0.114)), 0.16, 1.0);\n    vec3 blueShadow = vec3(0.86, 0.91, 0.97);\n    float lighting = mix(0.82 + luminance * 0.14, 0.90 + luminance * 0.08, farBlend);\n    return blueShadow * lighting;\n}\n\nuint teslesBlockHash(vec3 worldPos, uint face) {\n    vec3 p = worldPos;\n    if (face == 0u) p.y += 0.02;\n    else if (face == 1u) p.y -= 0.02;\n    else if (face == 2u) p.z += 0.02;\n    else if (face == 3u) p.z -= 0.02;\n    else if (face == 4u) p.x += 0.02;\n    else if (face == 5u) p.x -= 0.02;\n    ivec3 cell = ivec3(floor(p));\n    return uint(cell.x) * 0x9E3779B9u ^ uint(cell.y) * 0x85EBCA6Bu ^ uint(cell.z) * 0xC2B2AE35u ^ uint(teslesVisualSeed);\n}\n\nvec3 teslesApplyTerrainSnow(vec3 rgb, uint category, uint physicalFace, vec3 worldPos) {\n    if (teslesSnowCover <= 0.005) return rgb;\n    float snow = teslesSnowMask(worldPos);\n    if (snow <= 0.001) return rgb;\n    float farBlend = teslesVoxyDistanceBlend(worldPos);\n\n    // Up-facing terrain receives the full snow blanket. Natural terrain slabs are classified as\n    // category 4, so their LOD tops no longer remain green while the nearby slab is physically snowy.\n    if ((category == 4u || category == 6u) && physicalFace == 1u) {\n        float strength = snow * mix(0.965, 0.995, farBlend);\n        return mix(rgb, teslesSnowTopColour(rgb, farBlend), clamp(strength, 0.0, 1.0));\n    }\n\n    #ifndef TRANSLUCENT\n    // Safety net for opaque states whose Iris custom id was too large to carry a TESLES category.\n    // Only the exposed UP face is affected, so unknown buildings/rocks gain a plausible snow cap\n    // instead of punching dark holes into an otherwise white distant winter. Water stays untouched.\n    if (category == 0u && physicalFace == 1u) {\n        float strength = snow * mix(0.82, 0.94, farBlend);\n        return mix(rgb, teslesSnowTopColour(rgb, farBlend), clamp(strength, 0.0, 0.95));\n    }\n    #endif\n\n    // The ugly horizontal contour rails came from Voxy keeping grass/dirt/slab SIDE faces fully\n    // green underneath a white top. Give genuine terrain sides a cool snow-shadow treatment. It is\n    // intentionally weaker close to the vanilla render radius and stronger in coarse far LODs.\n    if (category == 4u && physicalFace >= 2u) {\n        float sideStrength = snow * mix(0.62, 0.92, farBlend);\n        return mix(rgb, teslesSnowSideColour(rgb, farBlend), clamp(sideStrength, 0.0, 0.90));\n    }\n\n    // Coarse LOD terrain exposes dirt/stone substrate as vertical voxel steps even when the real\n    // surface is a smooth snow-covered slope. A restrained far-only snow bounce removes those dark\n    // ruler-straight rails without turning nearby building walls into snow blocks.\n    if (category == 6u && physicalFace >= 2u && farBlend > 0.001) {\n        float substrateStrength = snow * farBlend * 0.42;\n        return mix(rgb, teslesSnowSideColour(rgb, farBlend), clamp(substrateStrength, 0.0, 0.36));\n    }\n\n    #ifndef TRANSLUCENT\n    if (category == 0u && physicalFace >= 2u && farBlend > 0.55) {\n        float conflictSoftening = snow * smoothstep(0.55, 1.0, farBlend) * 0.18;\n        return mix(rgb, teslesSnowSideColour(rgb, farBlend), conflictSoftening);\n    }\n    #endif\n\n    return rgb;\n}\n\nvec3 teslesSeasonColour(vec3 rgb, uint category, uint physicalFace, vec3 worldPos) {\n    if (category == 1u) {\n        rgb = mix(rgb, vec3(0.61, 0.43, 0.21), clamp(teslesAutumn * 0.72, 0.0, 0.82));\n        rgb = mix(rgb, vec3(0.51, 0.45, 0.33), clamp(teslesDormancy * 0.16, 0.0, 0.20));\n        rgb = mix(rgb, vec3(0.43, 0.64, 0.34), clamp(teslesSpringFresh * 0.12, 0.0, 0.14));\n    } else if (category == 2u) {\n        rgb = mix(rgb, vec3(0.57, 0.50, 0.28), clamp(teslesAutumn * 0.28, 0.0, 0.32));\n        rgb = mix(rgb, vec3(0.62, 0.58, 0.43), clamp(teslesDormancy * 0.38, 0.0, 0.42));\n        rgb = mix(rgb, vec3(0.50, 0.67, 0.36), clamp(teslesSpringFresh * 0.10, 0.0, 0.12));\n    } else if (category == 3u) {\n        float gray = dot(rgb, vec3(0.299, 0.587, 0.114));\n        rgb = mix(rgb, vec3(gray) * vec3(0.92, 0.98, 0.90), clamp(teslesDormancy * 0.12, 0.0, 0.14));\n        if (physicalFace == 1u && teslesSnowCover > 0.05) {\n            float coniferSnow = teslesSnowMask(worldPos) * clamp(teslesSnowCover * 0.48, 0.0, 0.48);\n            rgb = mix(rgb, teslesSnowTopColour(rgb, teslesVoxyDistanceBlend(worldPos)), coniferSnow);\n        }\n    } else if (category == 4u) {\n        rgb = mix(rgb, vec3(0.55, 0.50, 0.33), clamp(teslesAutumn * 0.12, 0.0, 0.14));\n        rgb = mix(rgb, vec3(0.67, 0.65, 0.55), clamp(teslesDormancy * 0.09, 0.0, 0.10));\n    } else if (category == 5u) {\n        rgb = mix(rgb, vec3(0.72, 0.65, 0.49), clamp(teslesDormancy * 0.22, 0.0, 0.24));\n        rgb = mix(rgb, vec3(0.72, 0.62, 0.39), clamp(teslesAutumn * 0.13, 0.0, 0.15));\n    } else if (category == 7u) {\n        // FarmSeasons owns crop growth. Only a restrained frost cue is shown here.\n        rgb = mix(rgb, vec3(0.90, 0.91, 0.90), clamp(teslesSnowCover * 0.16, 0.0, 0.18));\n    } else if (category == 8u) {\n        rgb = mix(rgb, vec3(0.58, 0.50, 0.38), clamp(teslesDormancy * 0.12, 0.0, 0.14));\n    } else if (category == 9u) {\n        rgb = mix(rgb, vec3(0.93, 0.95, 0.97), clamp(teslesSnowCover * 0.90, 0.0, 0.94));\n    }\n    return teslesApplyTerrainSnow(rgb, category, physicalFace, worldPos);\n}\n\nuint teslesOriginalCustomId(uint customId) {\n    if ((customId & 0xC0000000u) == 0x40000000u) return customId & 0x03FFFFFFu;\n    uint high = customId >> 24u;\n    return ((high & 0xF0u) == 0xA0u) ? (customId & 0x00FFFFFFu) : customId;\n}\n";
            String discard = alphaAnchor.replace(
               "\n\n    #ifndef PATCHED_SHADER",
               "\nfloat teslesBlockNoise = teslesHash01(teslesBlockHash(teslesWorldPos, getFace()));\nif (teslesSeasonCategory == 1u && teslesLeafRetention < 0.999 &&\n        (teslesLeafRetention <= 0.001 || teslesBlockNoise > teslesLeafRetention)) {\n    discard;\n    return;\n}\nif (teslesSeasonCategory == 5u && teslesFlowerRetention < 0.999 &&\n        (teslesFlowerRetention <= 0.001 || teslesBlockNoise > teslesFlowerRetention)) {\n    discard;\n    return;\n}\nif (teslesSeasonCategory == 8u && teslesMushroomRetention < 0.999 &&\n        (teslesMushroomRetention <= 0.001 || teslesBlockNoise > teslesMushroomRetention)) {\n    discard;\n    return;\n}\nif ((teslesSeasonCategory == 2u || teslesSeasonCategory == 5u || teslesSeasonCategory == 8u || teslesSeasonCategory == 9u)\n        && teslesSnowCover > 0.005) {\n    float teslesPlantSnow = teslesSnowMask(teslesWorldPos);\n    if (teslesPlantSnow > 0.50) {\n        discard;\n        return;\n    }\n}\n\n#ifndef PATCHED_SHADER"
            );
            String nonPatched = "colour = computeColour(texPos, colour);\ncolour.rgb = teslesSeasonColour(colour.rgb, teslesSeasonCategory, getFace(), teslesWorldPos);\noutColour = colour;";
            String patchedFace = "uint face = getFace();\nuint teslesPhysicalFace = face;\nif (doTint) {\n    tint.rgb = teslesSeasonColour(tint.rgb, teslesSeasonCategory, teslesPhysicalFace, teslesWorldPos);\n} else {\n    colour.rgb = teslesSeasonColour(colour.rgb, teslesSeasonCategory, teslesPhysicalFace, teslesWorldPos);\n}\nface ^= uint((face&1u)!=uint(gl_FrontFacing!=((face>>1)!=0u)));\nvoxy_emitFragment(VoxyFragmentParameters(colour, tile, texPos, face, modelId, getLightmapUv(interData.y), tint, teslesOriginalCustomId(model.customId)));";
            String patched = source.replace(ioAnchor, io)
               .replace(functionAnchor, functions)
               .replace(alphaAnchor, discard)
               .replace(nonPatchedAnchor, nonPatched)
               .replace(patchedFaceAnchor, patchedFace);
            VoxyShaderDiagnostics.markFragmentPatched();
            if (!fragmentLogged) {
               fragmentLogged = true;
               TeslesSeasons.LOGGER
                  .info("TESLES Voxy snowfield bridge applied: distance blend, terrain-side snow shadows, slab terrain coverage and instant season uniforms.");
            }

            return patched;
         } else {
            if (!fragmentWarned) {
               fragmentWarned = true;
               TeslesSeasons.LOGGER.warn("Voxy fragment shader layout differs from 0.2.18-beta; TESLES seasonal LOD bridge skipped safely.");
            }

            return source;
         }
      }
   }
}
