package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.system.SeasonCoordinateField;
import fi.tesles.seasons.world.system.SnowSystem;
import java.util.TreeSet;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * The release-blocking parity invariant: for any coordinate and any SeasonFrame, the target
 * the server places physically and the target Voxy renders must be identical.
 *
 * <p>Three code paths decide whether a column is snowy: the physical projector, the Voxy LOD
 * mesh projector and the Voxy fragment shader. Before this suite existed the mesh projector
 * used a warped multi-octave "organic" noise field while the other two used the flat
 * coordinate hash, so near and far terrain disagreed at every partial coverage - visible as a
 * hard seam at the LOD boundary and as distant terrain that never matched the ground.
 */
class VoxySnowParityTest {
   private static final long SEED = 7302026L;

   private static SeasonFrame frame(Season season, CalendarPhase phase, float p) {
      return SeasonTestSupport.frame(season, phase, p);
   }

   // ---------------------------------------------------------------- shader <-> physical

   /**
    * Java transcription of the GLSL {@code teslesCellNoise} installed by
    * VoxyCanonicalVisualPostPatch. GLSL uint arithmetic maps to Java int with unsigned shifts.
    */
   private static float glslCellNoise(int cellX, int cellY, int salt, long visualSeed) {
      int h = cellX * 0x9E3779B9 ^ cellY * 0x85EBCA6B ^ (int) visualSeed ^ salt;
      h ^= h >>> 16;
      h *= 0x7FEB352D;
      h ^= h >>> 15;
      h *= 0x846CA68B;
      h ^= h >>> 16;
      return (h & 0x00FFFFFF) / 16777215.0F;
   }

   @Test
   @DisplayName("the Voxy shader snow mask is a bit-exact mirror of the physical coordinate field")
   void shaderMirrorsPhysicalField() {
      int mismatches = 0;
      int checked = 0;
      for (int x = -1000; x < 1000; x += 7) {
         for (int z = -1000; z < 1000; z += 7) {
            float physical = SeasonCoordinateField.snowCoverage01(x, z, SEED);
            float shader = glslCellNoise(x, z, SeasonCoordinateField.SNOW_COVERAGE_SALT, SEED);
            checked++;
            if (Float.compare(physical, shader) != 0) {
               mismatches++;
            }
         }
      }
      assertTrue(checked > 80_000, "sample too small: " + checked);
      assertEquals(0, mismatches,
         "shader/physical field mismatch on %d of %d coordinates".formatted(mismatches, checked));
   }

   @Test
   @DisplayName("shader and physical agree on membership at every coverage level")
   void shaderMembershipMatches() {
      for (float coverage : new float[]{0.05F, 0.25F, 0.5F, 0.75F, 0.95F}) {
         int mismatches = 0;
         for (int x = -400; x < 400; x += 3) {
            for (int z = -400; z < 400; z += 3) {
               boolean physical = SeasonCoordinateField.snowCoverage01(x, z, SEED) < coverage;
               boolean shader = glslCellNoise(x, z, SeasonCoordinateField.SNOW_COVERAGE_SALT, SEED) < coverage;
               if (physical != shader) {
                  mismatches++;
               }
            }
         }
         assertEquals(0, mismatches, "membership mismatch at coverage " + coverage);
      }
   }

   // --------------------------------------------------------------- mesh <-> physical

   /**
    * The LOD column mapping used by VoxySeasonMeshProjectionMixin. At LOD 0 it must resolve to
    * exactly the block column the server evaluates, or parity is lost by a half-voxel offset.
    */
   private static int lodColumn(int sectionCoord, int local, int lvl) {
      int half = (1 << lvl) >> 1;
      return (((sectionCoord << 5) + local) << lvl) + half;
   }

   @Test
   @DisplayName("LOD 0 mesh columns map to exact block coordinates")
   void lod0MapsToBlockCoordinates() {
      for (int section = -8; section <= 8; section++) {
         for (int local = 0; local < 32; local++) {
            int expected = (section << 5) + local;
            assertEquals(expected, lodColumn(section, local, 0),
               "LOD 0 must address the same block column the server does");
         }
      }
   }

   @Test
   @DisplayName("mesh projector and physical projector choose identical snow at LOD 0")
   void meshMatchesPhysicalAtLod0() {
      SeasonFrame[] frames = {
         frame(Season.AUTUMN, CalendarPhase.OUTGOING, 0.25F),
         frame(Season.WINTER, CalendarPhase.INCOMING, 0.5F),
         frame(Season.WINTER, CalendarPhase.STABLE, 0.54F),
         frame(Season.WINTER, CalendarPhase.OUTGOING, 0.75F)
      };

      for (SeasonFrame f : frames) {
         int mismatches = 0;
         int checked = 0;
         for (int sx = -4; sx <= 4; sx++) {
            for (int sz = -4; sz <= 4; sz++) {
               for (int lx = 0; lx < 32; lx++) {
                  for (int lz = 0; lz < 32; lz++) {
                     // What the LOD mesh projector samples...
                     int meshX = lodColumn(sx, lx, 0);
                     int meshZ = lodColumn(sz, lz, 0);
                     int mesh = SnowSystem.targetLayers(f, meshX, meshZ, SEED);

                     // ...against the block column the server actually places snow in.
                     int worldX = (sx << 5) + lx;
                     int worldZ = (sz << 5) + lz;
                     int physical = SnowSystem.targetLayers(f, worldX, worldZ, SEED);

                     checked++;
                     if (mesh != physical) {
                        mismatches++;
                     }
                  }
               }
            }
         }
         assertEquals(9 * 9 * 32 * 32, checked, "expected full sample");
         assertEquals(0, mismatches,
            "physical/Voxy mismatch on %d of %d columns for %s %s"
               .formatted(mismatches, checked, f.season(), f.phase()));
      }
   }

   @Test
   @DisplayName("coarse LOD columns sample inside the area the voxel covers")
   void coarseLodSamplesInsideItsFootprint() {
      for (int lvl = 1; lvl <= 2; lvl++) {
         int scale = 1 << lvl;
         for (int section = -4; section <= 4; section++) {
            for (int local = 0; local < 32; local++) {
               int sampled = lodColumn(section, local, lvl);
               int footprintStart = ((section << 5) + local) << lvl;
               int footprintEnd = footprintStart + scale - 1;
               assertTrue(sampled >= footprintStart && sampled <= footprintEnd,
                  "LOD %d sample %d escapes its own footprint [%d,%d]"
                     .formatted(lvl, sampled, footprintStart, footprintEnd));
            }
         }
      }
   }

   // ------------------------------------------------------------------ snow contracts

   @Test
   @DisplayName("Autumn Outgoing 25%: about 25% footprint, exactly 1/8 where present")
   void autumnOutgoingFirstSnow() {
      SeasonFrame f = frame(Season.AUTUMN, CalendarPhase.OUTGOING, 0.25F);
      int covered = 0;
      int total = 0;
      TreeSet<Integer> observed = new TreeSet<>();
      for (int x = 0; x < 400; x++) {
         for (int z = 0; z < 400; z++) {
            int layers = SnowSystem.targetLayers(f, x, z, SEED);
            total++;
            if (layers > 0) {
               covered++;
               observed.add(layers);
            }
         }
      }
      assertEquals(0.25F, covered / (float) total, 0.01F, "footprint");
      assertEquals(new TreeSet<>(java.util.List.of(1)), observed,
         "Autumn Outgoing expresses coverage, not depth: only 1/8 is legal");
   }

   @Test
   @DisplayName("Winter Stable 54%: full footprint, only 4/8 and 5/8, mean about 4.32")
   void winterStable54() {
      SeasonFrame f = frame(Season.WINTER, CalendarPhase.STABLE, 0.54F);
      long sum = 0;
      int covered = 0;
      int total = 0;
      TreeSet<Integer> observed = new TreeSet<>();
      for (int x = 0; x < 400; x++) {
         for (int z = 0; z < 400; z++) {
            int layers = SnowSystem.targetLayers(f, x, z, SEED);
            total++;
            if (layers > 0) {
               covered++;
               sum += layers;
               observed.add(layers);
            }
         }
      }
      assertEquals(1.0F, covered / (float) total, 0.001F, "winter stable footprint is complete");
      assertEquals(new TreeSet<>(java.util.List.of(4, 5)), observed,
         "only 4/8 and 5/8 placements are legal at 54%");
      assertEquals(4.32, sum / (double) covered, 0.02, "large-area mean depth");
   }

   @Test
   @DisplayName("Winter Stable exact eighths land on a single layer value")
   void winterStableExactEighths() {
      for (int eighth = 1; eighth <= 8; eighth++) {
         float progress = eighth / 8.0F;
         SeasonFrame f = frame(Season.WINTER, CalendarPhase.STABLE, progress);
         TreeSet<Integer> observed = new TreeSet<>();
         for (int x = 0; x < 200; x++) {
            for (int z = 0; z < 200; z++) {
               int layers = SnowSystem.targetLayers(f, x, z, SEED);
               if (layers > 0) {
                  observed.add(layers);
               }
            }
         }
         assertEquals(new TreeSet<>(java.util.List.of(eighth)), observed,
            "progress %.3f should be exactly %d/8".formatted(progress, eighth));
      }
   }

   @Test
   @DisplayName("Winter Outgoing 75%: about 25% footprint remains, mean depth about 2/8")
   void winterOutgoing75() {
      SeasonFrame f = frame(Season.WINTER, CalendarPhase.OUTGOING, 0.75F);
      long sum = 0;
      int covered = 0;
      int total = 0;
      for (int x = 0; x < 400; x++) {
         for (int z = 0; z < 400; z++) {
            int layers = SnowSystem.targetLayers(f, x, z, SEED);
            total++;
            if (layers > 0) {
               covered++;
               sum += layers;
            }
         }
      }
      assertEquals(0.25F, covered / (float) total, 0.01F, "remaining footprint");
      assertEquals(2.0, sum / (double) covered, 0.05, "remaining mean depth");
   }

   @Test
   @DisplayName("only legal 1/8..8/8 snow layer states are ever produced")
   void onlyLegalLayerStates() {
      for (SeasonTestSupport.PhaseRef ref : SeasonTestSupport.cycle()) {
         for (float p : SeasonTestSupport.CHECKPOINTS) {
            SeasonFrame f = frame(ref.season(), ref.phase(), p);
            for (int x = 0; x < 60; x++) {
               for (int z = 0; z < 60; z++) {
                  int layers = SnowSystem.targetLayers(f, x, z, SEED);
                  assertTrue(layers >= 0 && layers <= 8,
                     "illegal layer count %d at %s %.2f".formatted(layers, ref, p));
               }
            }
         }
      }
   }

   @Test
   @DisplayName("no seasonal snow exists in Spring or Summer, or at Winter Outgoing 100%")
   void noSnowWhereContractForbidsIt() {
      SeasonFrame[] noSnow = {
         frame(Season.SPRING, CalendarPhase.INCOMING, 0.0F),
         frame(Season.SPRING, CalendarPhase.OUTGOING, 1.0F),
         frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F),
         frame(Season.WINTER, CalendarPhase.OUTGOING, 1.0F)
      };
      for (SeasonFrame f : noSnow) {
         for (int x = 0; x < 200; x++) {
            for (int z = 0; z < 200; z++) {
               assertEquals(0, SnowSystem.targetLayers(f, x, z, SEED),
                  "unexpected snow in " + f.season() + " " + f.phase());
            }
         }
      }
   }
}
