package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.client.voxy.VoxyCanonicalVisualPostPatch;
import fi.tesles.seasons.client.voxy.VoxySeasonShaderPatch;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Runs the whole GLSL injection pipeline against Voxy 0.2.18-beta's real shader sources.
 *
 * <p>The shader path is the easiest part of this mod to break silently. Every stage is
 * string replacement anchored on tokens from Voxy's source or from an earlier stage; if any
 * anchor stops matching, the stage returns the input unchanged and the game renders with no
 * error, no log line, and no season in the distance. Nothing but a test like this notices.
 *
 * <p>This is also why the corrections stage was folded out of a mixin and into
 * {@link VoxySeasonShaderPatch}: a mixin cannot be exercised from a unit test, so a third of
 * the pipeline used to be untestable by construction.
 */
class VoxyShaderPipelineTest {
   private static final String VOXY_JAR = "libs/voxy-0.2.18-beta.jar";
   private static final String FRAGMENT = "voxy:lod/gl46/quads.frag";
   private static final String VERTEX = "voxy:lod/gl46/quads3.vert";

   private static String rawFragment;
   private static String rawVertex;

   @BeforeAll
   static void loadRealShaders() throws IOException {
      Path jar = Path.of(VOXY_JAR);
      assertTrue(Files.exists(jar), "Voxy jar missing at " + jar.toAbsolutePath());
      try (ZipFile zip = new ZipFile(jar.toFile())) {
         rawFragment = read(zip, "assets/voxy/shaders/lod/gl46/quads.frag");
         rawVertex = read(zip, "assets/voxy/shaders/lod/gl46/quads3.vert");
      }
   }

   private static String read(ZipFile zip, String name) throws IOException {
      ZipEntry e = zip.getEntry(name);
      assertTrue(e != null, "Voxy shader not found in jar: " + name);
      try (InputStream in = zip.getInputStream(e)) {
         return new String(in.readAllBytes(), StandardCharsets.UTF_8);
      }
   }

   /** The full pipeline exactly as VoxyShaderLoaderMixin applies it. */
   private static String pipeline(String resource, String source) {
      return VoxyCanonicalVisualPostPatch.patch(resource, VoxySeasonShaderPatch.transform(resource, source));
   }

   private static int count(String haystack, String needle) {
      int n = 0, i = 0;
      while ((i = haystack.indexOf(needle, i)) >= 0) {
         n++;
         i += needle.length();
      }
      return n;
   }

   @Test
   @DisplayName("the fragment shader is actually modified - anchors still match Voxy 0.2.18")
   void fragmentIsPatched() {
      String out = pipeline(FRAGMENT, rawFragment);
      assertFalse(out.equals(rawFragment),
         "pipeline made no change: an anchor no longer matches Voxy's shader, "
            + "and the season would silently not render in the distance");
      assertTrue(out.length() > rawFragment.length(), "patched shader should have grown");
   }

   @Test
   @DisplayName("the vertex shader is actually modified")
   void vertexIsPatched() {
      String out = pipeline(VERTEX, rawVertex);
      assertFalse(out.equals(rawVertex), "vertex pipeline made no change");
      assertTrue(out.contains("teslesWorldPos"), "world position varying must be injected");
   }

   @Test
   @DisplayName("every injected GLSL function is defined exactly once")
   void noDuplicateDefinitions() {
      String out = pipeline(FRAGMENT, rawFragment);
      for (String fn : new String[]{
         "float teslesHash01(", "float teslesCellNoise(", "float teslesValueNoise(",
         "float teslesSnowMask(", "vec3 teslesSnowTopColour(", "vec3 teslesSnowSideColour(",
         "vec3 teslesApplyTerrainSnow(", "vec3 teslesSeasonColour(",
         "float teslesVoxyDistanceBlend(", "uint teslesOriginalCustomId("
      }) {
         assertEquals(1, count(out, fn),
            "%s must be defined exactly once; a duplicate definition fails GLSL compilation "
               .formatted(fn) + "and would disable Voxy rendering entirely");
      }
   }

   @Test
   @DisplayName("the canonical coordinate-field snow mask wins over the organic one")
   void canonicalSnowMaskWins() {
      String out = pipeline(FRAGMENT, rawFragment);
      int mask = out.indexOf("float teslesSnowMask(");
      assertTrue(mask >= 0, "snow mask must be present");
      int end = out.indexOf('}', out.indexOf('{', mask));
      String body = out.substring(mask, out.indexOf("vec3 teslesSnowTopColour", mask));

      // The last stage must have replaced the multi-octave mask with the exact mirror of
      // SeasonCoordinateField.snowCoverage01, or near and distant snow pick different columns.
      assertTrue(body.contains("teslesCellNoise(blockCell, 0x6A09E667u)"),
         "snow mask must threshold the canonical coordinate hash, got:\n" + body);
      assertFalse(body.contains("teslesGroundNoise("),
         "snow mask still uses the organic multi-octave field; physical/Voxy parity is broken");
   }

   @Test
   @DisplayName("every uniform the injected GLSL reads is declared")
   void allUniformsDeclared() {
      String out = pipeline(FRAGMENT, rawFragment);
      for (String uniform : new String[]{
         "teslesAutumn", "teslesDormancy", "teslesLeafRetention", "teslesFlowerRetention",
         "teslesMushroomRetention", "teslesSnowCover", "teslesSnowDepth",
         "teslesPlantRetention", "teslesSpringFresh", "teslesVisualSeed",
         "teslesVoxyBlendStart", "teslesVoxyBlendEnd"
      }) {
         assertTrue(out.contains("uniform float " + uniform + ";")
               || out.contains("uniform int " + uniform + ";"),
            "GLSL reads " + uniform + " but never declares it");
         assertEquals(1, count(out, " " + uniform + ";"),
            uniform + " must be declared exactly once");
      }
   }

   @Test
   @DisplayName("the LOD level varying is declared on both sides of the pipeline")
   void lodVaryingMatches() {
      String frag = pipeline(FRAGMENT, rawFragment);
      String vert = pipeline(VERTEX, rawVertex);
      // teslesApplyTerrainSnow reads teslesVoxyLodLevel; without the vertex stage writing it
      // the shader fails to link.
      if (frag.contains("teslesVoxyLodLevel")) {
         assertTrue(vert.contains("out flat uint teslesVoxyLodLevel"),
            "fragment reads teslesVoxyLodLevel but the vertex shader never writes it");
         assertTrue(frag.contains("in flat uint teslesVoxyLodLevel"),
            "fragment must declare teslesVoxyLodLevel as an input");
      }
   }

   @Test
   @DisplayName("patching is idempotent - a shader reload must not inject twice")
   void patchingIsIdempotent() {
      String once = pipeline(FRAGMENT, rawFragment);
      String twice = pipeline(FRAGMENT, once);
      assertEquals(once, twice,
         "re-running the pipeline changed the shader again; a shader reload would keep "
            + "appending GLSL until it stops compiling");
   }

   private static int braceDepth(String s) {
      int d = 0;
      for (int i = 0; i < s.length(); i++) {
         char c = s.charAt(i);
         if (c == '{') d++;
         else if (c == '}') d--;
      }
      return d;
   }

   @Test
   @DisplayName("patching preserves the shader's brace balance")
   void bracePreservation() {
      // Voxy's raw sources are not brace-balanced as plain text: #ifdef branches legitimately
      // open and close braces asymmetrically. So the invariant is that patching does not
      // change the balance, not that the balance is zero.
      for (String[] pair : new String[][]{{FRAGMENT, rawFragment}, {VERTEX, rawVertex}}) {
         String out = pipeline(pair[0], pair[1]);
         assertEquals(braceDepth(pair[1]), braceDepth(out),
            pair[0] + ": patching changed the brace balance, so a replacement lost or gained a block");
         int depth = 0;
         for (int i = 0; i < out.length(); i++) {
            char c = out.charAt(i);
            if (c == '{') depth++;
            else if (c == '}') depth--;
            assertTrue(depth >= -braceDepth(pair[1]) - 1,
               pair[0] + ": stray closing brace at offset " + i);
         }
      }
   }

   @Test
   @DisplayName("unrelated shaders are passed through untouched")
   void unrelatedShadersUntouched() {
      String other = "#version 460 core\nvoid main() { }\n";
      assertEquals(other, pipeline("voxy:lod/gl46/cull/raster.frag", other));
   }
}
