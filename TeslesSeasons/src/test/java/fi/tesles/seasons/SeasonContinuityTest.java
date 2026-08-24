package fi.tesles.seasons;

import static fi.tesles.seasons.SeasonTestSupport.PHASES;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Function;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Release-blocking invariant: every continuous SeasonFrame channel must leave a phase at
 * exactly the value the next phase enters with, at all 12 phase boundaries.
 *
 * <p>A jump such as groundDormancy going from 1.00 to 0.12 at midnight is a defect, not a
 * cosmetic detail: it is visible as the whole world changing appearance in one tick.
 */
class SeasonContinuityTest {
   /** Tolerance is float epsilon; these are meant to match exactly, not approximately. */
   private static final float EPSILON = 1.0E-6F;

   /**
    * Snow depth is only meaningful where coverage selects a column, so the continuous
    * quantity across boundaries is coverage*depth rather than depth alone.
    */
   private static final Map<String, Function<SeasonFrame, Float>> CONTINUOUS_CHANNELS =
      new LinkedHashMap<>() {{
         put("autumnColor", SeasonFrame::autumnColor);
         put("leafRetention", SeasonFrame::leafRetention);
         put("flowerRetention", SeasonFrame::flowerRetention);
         put("plantRetention", SeasonFrame::plantRetention);
         put("mushroomRetention", SeasonFrame::mushroomRetention);
         put("berryRetention", SeasonFrame::berryRetention);
         put("groundDormancy", SeasonFrame::groundDormancy);
         put("groundFrost", SeasonFrame::groundFrost);
         put("snowCoverage", SeasonFrame::snowCoverage);
         put("effectiveSnow", SeasonFrame::effectiveSnow);
         put("springFreshness", SeasonFrame::springFreshness);
         put("treeGrowthFactor", SeasonFrame::treeGrowthFactor);
         put("seedDropFactor", SeasonFrame::seedDropFactor);
         put("fruitProductionFactor", SeasonFrame::fruitProductionFactor);
      }};

   @Test
   @DisplayName("all continuous channels match exactly across all 12 phase boundaries")
   void allBoundariesAreContinuous() {
      List<String> failures = new ArrayList<>();
      int checks = 0;

      List<SeasonTestSupport.PhaseRef> cycle = SeasonTestSupport.cycle();
      for (int i = 0; i < cycle.size(); i++) {
         SeasonTestSupport.PhaseRef from = cycle.get(i);
         SeasonTestSupport.PhaseRef to = cycle.get((i + 1) % cycle.size());

         SeasonFrame end = SeasonTestSupport.frame(from.season(), from.phase(), 1.0F);
         SeasonFrame start = SeasonTestSupport.frame(to.season(), to.phase(), 0.0F);

         for (Map.Entry<String, Function<SeasonFrame, Float>> channel : CONTINUOUS_CHANNELS.entrySet()) {
            float a = channel.getValue().apply(end);
            float b = channel.getValue().apply(start);
            checks++;
            if (Math.abs(a - b) > EPSILON) {
               failures.add("%s -> %s : %s jumps %.6f -> %.6f"
                  .formatted(from, to, channel.getKey(), a, b));
            }
         }
      }

      assertTrue(failures.isEmpty(),
         "%d/%d boundary continuity checks failed:%n%s"
            .formatted(failures.size(), checks, String.join("\n", failures)));
      assertEquals(12 * CONTINUOUS_CHANNELS.size(), checks, "expected 12 boundaries x channels");
   }

   @Test
   @DisplayName("channels are monotonic within a phase where the contract requires it")
   void noDiscontinuityInsideAPhase() {
      List<String> failures = new ArrayList<>();
      for (SeasonTestSupport.PhaseRef ref : SeasonTestSupport.cycle()) {
         SeasonFrame previous = null;
         for (int step = 0; step <= 200; step++) {
            float p = step / 200.0F;
            SeasonFrame f = SeasonTestSupport.frame(ref.season(), ref.phase(), p);
            if (previous != null) {
               for (Map.Entry<String, Function<SeasonFrame, Float>> channel : CONTINUOUS_CHANNELS.entrySet()) {
                  float delta = Math.abs(channel.getValue().apply(f) - channel.getValue().apply(previous));
                  // A single 0.5% step must never move a channel by more than 5%.
                  if (delta > 0.05F) {
                     failures.add("%s at p=%.3f : %s stepped %.4f".formatted(ref, p, channel.getKey(), delta));
                  }
               }
            }
            previous = f;
         }
      }
      assertTrue(failures.isEmpty(), "in-phase discontinuities:\n" + String.join("\n", failures));
   }

   @Test
   @DisplayName("cycle order is Summer -> Autumn -> Winter -> Spring")
   void cycleOrderMatchesCalendar() {
      assertEquals(Season.AUTUMN, SeasonTestSupport.next(Season.SUMMER));
      assertEquals(Season.WINTER, SeasonTestSupport.next(Season.AUTUMN));
      assertEquals(Season.SPRING, SeasonTestSupport.next(Season.WINTER));
      assertEquals(Season.SUMMER, SeasonTestSupport.next(Season.SPRING));
      assertEquals(3, PHASES.length);
      assertEquals(CalendarPhase.INCOMING, PHASES[0]);
   }
}
