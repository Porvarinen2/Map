package fi.tesles.seasons;

import static fi.tesles.seasons.SeasonTestSupport.CHECKPOINTS;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * The 96-checkpoint grid: every one of the 12 phases evaluated at 0%, 1%, 10%, 25%, 50%,
 * 75%, 99% and 100%, asserted against the canonical phase contracts.
 *
 * <p>These assert what the world should look like, never how much scheduler work has run.
 */
class SeasonCheckpointContractTest {
   private static final float TOL = 1.0E-4F;

   @Test
   @DisplayName("96/96 phase checkpoints satisfy the canonical contracts")
   void allCheckpointsHold() {
      List<String> failures = new ArrayList<>();
      int evaluated = 0;

      for (SeasonTestSupport.PhaseRef ref : SeasonTestSupport.cycle()) {
         for (float p : CHECKPOINTS) {
            SeasonFrame f = SeasonTestSupport.frame(ref.season(), ref.phase(), p);
            evaluated++;
            check(failures, ref, p, f);
         }
      }

      assertEquals(96, evaluated, "checkpoint grid must be 12 phases x 8 progress values");
      assertTrue(failures.isEmpty(),
         "%d/96 checkpoints failed:%n%s".formatted(failures.size(), String.join("\n", failures)));
   }

   private static void check(List<String> failures, SeasonTestSupport.PhaseRef ref, float p, SeasonFrame f) {
      Season season = ref.season();
      CalendarPhase phase = ref.phase();

      // --- Universal winter invariants -------------------------------------------------
      if (season == Season.WINTER) {
         expect(failures, ref, p, "leafRetention", f.leafRetention(), 0.0F);
         expect(failures, ref, p, "flowerRetention", f.flowerRetention(), 0.0F);
         expect(failures, ref, p, "mushroomRetention", f.mushroomRetention(), 0.0F);
         expect(failures, ref, p, "berryRetention", f.berryRetention(), 0.0F);
      }

      // --- Mushroom contract: Spring 0, Summer 0, Autumn I 0->1, S 1, O 1->0, Winter 0 ---
      float expectedMushrooms = switch (season) {
         case SPRING, SUMMER, WINTER -> 0.0F;
         case AUTUMN -> switch (phase) {
            case INCOMING -> p;
            case STABLE -> 1.0F;
            case OUTGOING -> 1.0F - p;
         };
      };
      expect(failures, ref, p, "mushroomRetention", f.mushroomRetention(), expectedMushrooms);

      // --- Snow contracts ---------------------------------------------------------------
      switch (season) {
         case SPRING, SUMMER -> {
            expect(failures, ref, p, "snowCoverage", f.snowCoverage(), 0.0F);
            expect(failures, ref, p, "effectiveSnow", f.effectiveSnow(), 0.0F);
         }
         case AUTUMN -> {
            if (phase == CalendarPhase.OUTGOING) {
               // Coverage grows 0->100%, every selected column is exactly one layer.
               expect(failures, ref, p, "snowCoverage", f.snowCoverage(), p);
               if (p > 0.0F) {
                  expect(failures, ref, p, "snowDepth(1/8)", f.snowDepth(), 0.125F);
               }
            } else {
               expect(failures, ref, p, "snowCoverage", f.snowCoverage(), 0.0F);
            }
         }
         case WINTER -> {
            switch (phase) {
               case INCOMING -> {
                  // Seamless handoff: never reset the completed footprint to zero.
                  expect(failures, ref, p, "snowCoverage", f.snowCoverage(), 1.0F);
                  expect(failures, ref, p, "snowDepth(1/8)", f.snowDepth(), 0.125F);
               }
               case STABLE -> {
                  expect(failures, ref, p, "snowCoverage", f.snowCoverage(), 1.0F);
                  expect(failures, ref, p, "snowDepth", f.snowDepth(), Math.max(0.125F, p));
               }
               case OUTGOING -> {
                  expect(failures, ref, p, "snowCoverage", f.snowCoverage(), 1.0F - p);
                  expect(failures, ref, p, "snowDepth", f.snowDepth(), 1.0F - p);
               }
            }
         }
      }

      // --- Leaf contract ----------------------------------------------------------------
      float expectedLeaves = switch (season) {
         case SUMMER -> 1.0F;
         case AUTUMN -> switch (phase) {
            case INCOMING -> 1.0F;
            case STABLE -> 1.0F - p;   // progress N == ~N% of canonical leaves absent
            case OUTGOING -> 0.0F;
         };
         case WINTER -> 0.0F;
         case SPRING -> switch (phase) {
            case INCOMING -> 0.0F;
            case STABLE -> p;
            case OUTGOING -> 1.0F;
         };
      };
      expect(failures, ref, p, "leafRetention", f.leafRetention(), expectedLeaves);

      // --- Spring-wide flora restoration spans all three Spring phases 0 -> 1 -----------
      if (season == Season.SPRING) {
         float expectedFlora = switch (phase) {
            case INCOMING -> p / 3.0F;
            case STABLE -> (1.0F + p) / 3.0F;
            case OUTGOING -> (2.0F + p) / 3.0F;
         };
         expect(failures, ref, p, "flowerRetention", f.flowerRetention(), expectedFlora);
      }
      if (season == Season.SUMMER) {
         expect(failures, ref, p, "flowerRetention", f.flowerRetention(), 1.0F);
      }

      // --- Summer Outgoing runs the autumn colour transform while leaves stay at 100% ---
      if (season == Season.SUMMER && phase == CalendarPhase.OUTGOING) {
         expect(failures, ref, p, "autumnColor", f.autumnColor(), p);
         expect(failures, ref, p, "leafRetention", f.leafRetention(), 1.0F);
      }

      // --- Every channel must stay a legal normalised target ----------------------------
      for (float v : new float[]{
         f.progress(), f.autumnColor(), f.leafRetention(), f.flowerRetention(),
         f.plantRetention(), f.mushroomRetention(), f.berryRetention(), f.groundDormancy(),
         f.groundFrost(), f.snowCoverage(), f.snowDepth(), f.springFreshness(),
         f.treeGrowthFactor(), f.seedDropFactor(), f.fruitProductionFactor()
      }) {
         if (!(v >= 0.0F && v <= 1.0F) || Float.isNaN(v)) {
            failures.add("%s @ %.2f : channel out of range: %s".formatted(ref, p, v));
         }
      }
   }

   @Test
   @DisplayName("named checkpoint examples from the specification")
   void namedCheckpoints() {
      // Summer Outgoing 40%: autumn transform 40%, no winter snow.
      SeasonFrame a = SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.OUTGOING, 0.40F);
      assertEquals(0.40F, a.autumnColor(), TOL);
      assertEquals(0.0F, a.snowCoverage(), TOL);

      // Autumn Incoming 50%: about half of seasonal mushrooms selected.
      assertEquals(0.50F, SeasonTestSupport.frame(Season.AUTUMN, CalendarPhase.INCOMING, 0.50F)
         .mushroomRetention(), TOL);

      // Autumn Stable 70%: ~70% of canonical deciduous leaves absent.
      assertEquals(0.30F, SeasonTestSupport.frame(Season.AUTUMN, CalendarPhase.STABLE, 0.70F)
         .leafRetention(), TOL);

      // Autumn Outgoing 25%: ~25% footprint, exactly 1/8 where present.
      SeasonFrame b = SeasonTestSupport.frame(Season.AUTUMN, CalendarPhase.OUTGOING, 0.25F);
      assertEquals(0.25F, b.snowCoverage(), TOL);
      assertEquals(0.125F, b.snowDepth(), TOL);

      // Winter Stable 25% / 50% / 54% / 75%: full footprint, depth follows progress.
      for (float[] pair : new float[][]{{0.25F, 0.25F}, {0.50F, 0.50F}, {0.54F, 0.54F}, {0.75F, 0.75F}}) {
         SeasonFrame w = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.STABLE, pair[0]);
         assertEquals(1.0F, w.snowCoverage(), TOL, "winter stable footprint");
         assertEquals(pair[1], w.snowDepth(), TOL, "winter stable depth @" + pair[0]);
      }

      // Winter Outgoing 50% / 75% / 100%.
      SeasonFrame m50 = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.OUTGOING, 0.50F);
      assertEquals(0.50F, m50.snowCoverage(), TOL);
      assertEquals(0.50F, m50.snowDepth(), TOL);
      SeasonFrame m75 = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.OUTGOING, 0.75F);
      assertEquals(0.25F, m75.snowCoverage(), TOL);
      assertEquals(0.25F, m75.snowDepth(), TOL);
      SeasonFrame m100 = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.OUTGOING, 1.0F);
      assertEquals(0.0F, m100.effectiveSnow(), TOL, "no seasonal snow remains");

      // Spring Stable 50%: about half the leaves back, flora restoration around midpoint.
      SeasonFrame s = SeasonTestSupport.frame(Season.SPRING, CalendarPhase.STABLE, 0.50F);
      assertEquals(0.50F, s.leafRetention(), TOL);
      assertEquals(0.50F, s.flowerRetention(), TOL);
   }

   private static void expect(List<String> failures, SeasonTestSupport.PhaseRef ref,
                              float p, String channel, float actual, float expected) {
      if (Math.abs(actual - expected) > TOL) {
         failures.add("%s @ %.2f : %s expected %.5f but was %.5f"
            .formatted(ref, p, channel, expected, actual));
      }
   }
}
