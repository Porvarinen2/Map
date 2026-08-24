package fi.tesles.seasons.client.voxy;

public final class VoxyCanonicalVisualPostPatch {
   private static final String FRAGMENT = "voxy:lod/gl46/quads.frag";

   private VoxyCanonicalVisualPostPatch() {
   }

   public static String patch(String resource, String source) {
      if ("voxy:lod/gl46/quads.frag".equals(resource) && source != null && source.contains("teslesSeasonColour") && source.contains("teslesSnowMask")) {
         String patched = addPlantRetentionUniform(source);
         patched = replaceSnowMask(patched);
         patched = replaceSeasonColour(patched);
         patched = patchUnpatchedTintPath(patched);
         patched = patchLeafRetentionPredicate(patched);
         return addPlantRetentionPredicate(patched);
      } else {
         return source;
      }
   }

   private static String addPlantRetentionUniform(String source) {
      return source.contains("uniform float teslesPlantRetention;")
         ? source
         : source.replace("uniform float teslesMushroomRetention;", "uniform float teslesMushroomRetention;\nuniform float teslesPlantRetention;");
   }

   private static String replaceSnowMask(String source) {
      String startToken = "float teslesSnowMask(vec3 worldPos) {";
      String endToken = "vec3 teslesSnowTopColour";
      int start = source.indexOf(startToken);
      int end = source.indexOf(endToken, start < 0 ? 0 : start);
      if (start >= 0 && end > start) {
         String exactMask = "float teslesSnowMask(vec3 worldPos) {\n    if (teslesSnowCover <= 0.005) return 0.0;\n    if (teslesSnowCover >= 0.9995) return 1.0;\n    // Exact mirror of SeasonCoordinateField.snowCoverage01(x,z,seed). This is deliberately\n    // block-random rather than broad value-noise: Winter OUTGOING therefore melts the same\n    // columns in Voxy that the server physically melts around the player.\n    ivec2 blockCell = ivec2(floor(worldPos.xz + vec2(0.0001)));\n    float n = teslesCellNoise(blockCell, 0x6A09E667u);\n    return n < clamp(teslesSnowCover, 0.0, 1.0) ? 1.0 : 0.0;\n}\n";
         return source.substring(0, start) + exactMask + source.substring(end);
      } else {
         return source;
      }
   }

   private static String replaceSeasonColour(String source) {
      String startToken = "vec3 teslesSeasonColour(vec3 rgb, uint category, uint physicalFace, vec3 worldPos) {";
      String endToken = "uint teslesOriginalCustomId";
      int start = source.indexOf(startToken);
      int end = source.indexOf(endToken, start < 0 ? 0 : start);
      if (start >= 0 && end > start) {
         String exactColour = "bool teslesIsDeciduousCategory(uint category) {\n    return category == 1u || (category >= 11u && category <= 15u);\n}\n\nvec3 teslesAutumnLeafTarget(uint category) {\n    // These are the exact RGB targets used by SeasonalClassifier.autumnLeafRgb in the near renderer.\n    if (category == 11u) return vec3(0.815686, 0.662745, 0.247059); // birch  #D0A93F\n    if (category == 12u) return vec3(0.482353, 0.298039, 0.180392); // dark oak #7B4C2E\n    if (category == 13u) return vec3(0.721569, 0.352941, 0.196078); // maple #B85A32\n    if (category == 14u) return vec3(0.780392, 0.658824, 0.294118); // aspen #C7A84B\n    if (category == 15u) return vec3(0.611765, 0.419608, 0.203922); // oak #9C6B34\n    return vec3(0.631373, 0.470588, 0.239216);                    // generic #A1783D\n}\n\nvec3 teslesSeasonColour(vec3 rgb, uint category, uint physicalFace, vec3 worldPos) {\n    if (teslesIsDeciduousCategory(category)) {\n        // Mirror SeasonalColorUtil.foliageColor as closely as Voxy's already-baked material allows.\n        vec3 target = teslesAutumnLeafTarget(category);\n        float initialBlend = clamp(0.22 + teslesAutumn * 0.74, 0.0, 1.0);\n        rgb = mix(rgb, target, initialBlend);\n        if (teslesAutumn > 0.60) {\n            float unify = clamp((teslesAutumn - 0.60) / 0.40, 0.0, 1.0);\n            rgb = mix(rgb, target, 0.55 * unify);\n        }\n        rgb = mix(rgb, vec3(0.509804, 0.490196, 0.427451), clamp(teslesDormancy * 0.22, 0.0, 1.0));\n        rgb = mix(rgb, vec3(0.435294, 0.678431, 0.466667), clamp(teslesSpringFresh * 0.16, 0.0, 1.0));\n    } else if (category == 2u) {\n        // Same multiplier family as near-rendered ground vegetation.\n        vec3 mul = vec3(1.0);\n        mul = mix(mul, vec3(0.839216, 0.725490, 0.470588), clamp(teslesAutumn * 0.30, 0.0, 1.0));\n        mul = mix(mul, vec3(0.780392, 0.756863, 0.372549), clamp(teslesDormancy * 0.42, 0.0, 1.0));\n        mul = mix(mul, vec3(0.874510, 0.960784, 0.811765), clamp(teslesSpringFresh * 0.10, 0.0, 1.0));\n        mul = mix(mul, vec3(0.890196, 0.823529, 0.835294), clamp(teslesSnowCover * 0.13, 0.0, 1.0));\n        rgb *= mul;\n    } else if (category == 3u) {\n        // Exact evergreen dormancy target from SeasonalColorUtil.foliageColor.\n        rgb = mix(rgb, vec3(0.435294, 0.454902, 0.431373), clamp(teslesDormancy * 0.18, 0.0, 1.0));\n        if (physicalFace == 1u && teslesSnowCover > 0.05) {\n            float coniferSnow = teslesSnowMask(worldPos) * clamp(teslesSnowCover * 0.48, 0.0, 0.48);\n            rgb = mix(rgb, teslesSnowTopColour(rgb, teslesVoxyDistanceBlend(worldPos)), coniferSnow);\n        }\n    } else if (category == 4u) {\n        // Mirror SeasonalColorUtil.grassColor instead of the old washed-out generic Voxy palette.\n        rgb = mix(rgb, vec3(0.545098, 0.498039, 0.270588), clamp(teslesAutumn * 0.36, 0.0, 1.0));\n        rgb = mix(rgb, vec3(0.505882, 0.498039, 0.333333), clamp(teslesDormancy * 0.48, 0.0, 1.0));\n        rgb = mix(rgb, vec3(0.447059, 0.647059, 0.309804), clamp(teslesSpringFresh * 0.13, 0.0, 1.0));\n    } else if (category == 5u) {\n        vec3 mul = vec3(1.0);\n        mul = mix(mul, vec3(0.882353, 0.835294, 0.717647), clamp(teslesDormancy * 0.26, 0.0, 1.0));\n        mul = mix(mul, vec3(0.901961, 0.796078, 0.615686), clamp(teslesAutumn * 0.16, 0.0, 1.0));\n        rgb *= mul;\n    } else if (category == 7u) {\n        // FarmSeasons owns crop growth. Only a restrained frost cue is shown here.\n        rgb = mix(rgb, vec3(0.90, 0.91, 0.90), clamp(teslesSnowCover * 0.16, 0.0, 0.18));\n    } else if (category == 8u) {\n        vec3 mul = vec3(1.0);\n        mul = mix(mul, vec3(0.839216, 0.725490, 0.470588), clamp(teslesAutumn * 0.30, 0.0, 1.0));\n        mul = mix(mul, vec3(0.780392, 0.756863, 0.372549), clamp(teslesDormancy * 0.42, 0.0, 1.0));\n        rgb *= mul;\n    } else if (category == 9u) {\n        rgb = mix(rgb, vec3(0.93, 0.95, 0.97), clamp(teslesSnowCover * 0.90, 0.0, 0.94));\n    }\n    return teslesApplyTerrainSnow(rgb, category, physicalFace, worldPos);\n}\n\n";
         return source.substring(0, start) + exactColour + source.substring(end);
      } else {
         return source;
      }
   }

   private static String patchUnpatchedTintPath(String source) {
      String oldPath = "colour = computeColour(texPos, colour);\ncolour.rgb = teslesSeasonColour(colour.rgb, teslesSeasonCategory, getFace(), teslesWorldPos);\noutColour = colour;";
      if (!source.contains(oldPath)) {
         return source;
      } else {
         String exactPath = "uint teslesTintingFunction = tintingState();\nbool teslesDoTint = teslesTintingFunction == 2u;\nif (teslesTintingFunction == 1u) {\n    vec4 teslesTintTest = textureLod(blockModelAtlas, texPos, 0);\n    if (abs(teslesTintTest.r - teslesTintTest.g) < 0.02f && abs(teslesTintTest.g - teslesTintTest.b) < 0.02f) {\n        teslesDoTint = true;\n    }\n}\nif (teslesDoTint) {\n    vec4 teslesExactTint = uint2vec4RGBA(interData.z).yzwx;\n    teslesExactTint.rgb = teslesSeasonColour(teslesExactTint.rgb, teslesSeasonCategory, getFace(), teslesWorldPos);\n    colour *= teslesExactTint;\n} else {\n    colour.rgb = teslesSeasonColour(colour.rgb, teslesSeasonCategory, getFace(), teslesWorldPos);\n}\ncolour = (colour * uint2vec4RGBA(interData.y)) + vec4(0, 0, 0, float(interData.w & 0xFFu) / 255.0);\noutColour = colour;\n";
         return source.replace(oldPath, exactPath.stripTrailing());
      }
   }

   private static String patchLeafRetentionPredicate(String source) {
      return source.replace(
         "if (teslesSeasonCategory == 1u && teslesLeafRetention < 0.999 &&",
         "if (teslesIsDeciduousCategory(teslesSeasonCategory) && teslesLeafRetention < 0.999 &&"
      );
   }

   private static String addPlantRetentionPredicate(String source) {
      if (source.contains("teslesSeasonCategory == 2u && teslesPlantRetention")) {
         return source;
      } else {
         String anchor = "if ((teslesSeasonCategory == 2u || teslesSeasonCategory == 5u || teslesSeasonCategory == 8u || teslesSeasonCategory == 9u)\n        && teslesSnowCover > 0.005) {";
         int at = source.indexOf(anchor);
         if (at < 0) {
            return source;
         } else {
            String plantGate = "if (teslesSeasonCategory == 2u && teslesPlantRetention < 0.999 &&\n        (teslesPlantRetention <= 0.001 || teslesBlockNoise > teslesPlantRetention)) {\n    discard;\n    return;\n}\n";
            return source.substring(0, at) + plantGate + source.substring(at);
         }
      }
   }
}
