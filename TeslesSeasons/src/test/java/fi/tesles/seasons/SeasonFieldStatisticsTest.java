package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.world.system.SeasonCoordinateField;
import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Statistical contract for the deterministic coordinate field.
 *
 * <p>A percentage target only means "this fraction of the world" if the field is uniform. If
 * the hash clumps, "25% snow" silently becomes 12% in one biome and 40% in another, and every
 * checkpoint in the season contract becomes unverifiable.
 */
class SeasonFieldStatisticsTest {
   private static final long SEED = 7302026L;
   private static final int SAMPLE = 512; // 512x512 columns per measurement

   @Test
   @DisplayName("coverage thresholds select approximately the requested fraction")
   void coverageIsUniform() {
      for (float target : new float[]{0.05F, 0.10F, 0.25F, 0.50F, 0.75F, 0.90F}) {
         int selected = 0;
         for (int x = 0; x < SAMPLE; x++) {
            for (int z = 0; z < SAMPLE; z++) {
               if (SeasonCoordinateField.snowCoverage01(x, z, SEED) < target) {
                  selected++;
               }
            }
         }
         float actual = selected / (float) (SAMPLE * SAMPLE);
         assertEquals(target, actual, 0.01F,
            "coverage at target %.2f measured %.4f".formatted(target, actual));
      }
   }

   @Test
   @DisplayName("depth field is uniform, so stochastic rounding converges to the target mean")
   void depthIsUniform() {
      for (float fractional : new float[]{0.0F, 0.32F, 0.5F, 0.75F}) {
         int rounded = 0;
         for (int x = 0; x < SAMPLE; x++) {
            for (int z = 0; z < SAMPLE; z++) {
               if (SeasonCoordinateField.snowDepth01(x, z, SEED) < fractional) {
                  rounded++;
               }
            }
         }
         float actual = rounded / (float) (SAMPLE * SAMPLE);
         assertEquals(fractional, actual, 0.01F,
            "depth rounding at %.2f measured %.4f".formatted(fractional, actual));
      }
   }

   @Test
   @DisplayName("channel salts are independent: no channel predicts another")
   void saltsAreIndependent() {
      int[] salts = {
         SeasonCoordinateField.SNOW_COVERAGE_SALT,
         SeasonCoordinateField.SNOW_DEPTH_SALT,
         SeasonCoordinateField.LEAF_SALT,
         SeasonCoordinateField.FLOWER_SALT,
         SeasonCoordinateField.GROUND_PLANT_SALT,
         SeasonCoordinateField.MUSHROOM_SALT,
         SeasonCoordinateField.BERRY_SALT
      };

      Set<Integer> distinct = new HashSet<>();
      for (int salt : salts) {
         distinct.add(salt);
      }
      assertEquals(salts.length, distinct.size(), "every channel needs its own salt");

      // Coverage and depth must not agree more often than chance. If they were correlated,
      // deep snow would always land on the same columns that get snow at all, producing
      // visible banding instead of an even field.
      int agree = 0;
      int n = 0;
      for (int x = 0; x < 256; x++) {
         for (int z = 0; z < 256; z++) {
            boolean a = SeasonCoordinateField.snowCoverage01(x, z, SEED) < 0.5F;
            boolean b = SeasonCoordinateField.snowDepth01(x, z, SEED) < 0.5F;
            if (a == b) {
               agree++;
            }
            n++;
         }
      }
      float rate = agree / (float) n;
      assertTrue(Math.abs(rate - 0.5F) < 0.02F,
         "coverage and depth salts are correlated: agreement %.4f".formatted(rate));
   }

   @Test
   @DisplayName("field is pure: repeated evaluation returns identical values")
   void fieldIsPure() {
      for (int i = 0; i < 1000; i++) {
         int x = i * 37 - 5000;
         int z = i * -91 + 1234;
         float first = SeasonCoordinateField.snowCoverage01(x, z, SEED);
         for (int repeat = 0; repeat < 3; repeat++) {
            assertEquals(first, SeasonCoordinateField.snowCoverage01(x, z, SEED), 0.0F,
               "field must be a pure function of its inputs");
         }
         assertTrue(first >= 0.0F && first < 1.0F, "field must stay in [0,1)");
      }
   }

   @Test
   @DisplayName("negative and large coordinates stay uniform")
   void handlesNegativeAndFarCoordinates() {
      for (int[] origin : new int[][]{{-4_000_000, -4_000_000}, {2_000_000, -2_000_000}, {-512, 30_000_000}}) {
         int selected = 0;
         int n = 0;
         for (int x = 0; x < 256; x++) {
            for (int z = 0; z < 256; z++) {
               if (SeasonCoordinateField.snowCoverage01(origin[0] + x, origin[1] + z, SEED) < 0.5F) {
                  selected++;
               }
               n++;
            }
         }
         float actual = selected / (float) n;
         assertEquals(0.5F, actual, 0.02F,
            "non-uniform near origin %d,%d: %.4f".formatted(origin[0], origin[1], actual));
      }
   }
}
