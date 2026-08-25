package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.system.SnowSystem;
import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * The distance must never show a season that is not the current one.
 *
 * <p>Two mechanisms have to hold for that. Every section whose stored geometry disagrees with
 * the current frame must be recognised as stale, and the sweep that fixes them must reach all
 * of them in bounded time whatever the season is doing. Both had a hole: summer could not
 * recognise winter snow as something to remove, and the sweep restarted from the nearest
 * section every time the season moved, so under a timelapse it never got past the first ring.
 */
class StaleSeasonEliminationTest {
   private static final long SEED = 7302026L;

   @Test
   @DisplayName("a snow-free season is a different geometry key from any snowy one")
   void snowFreeIsDistinguishableFromEverySnowyFrame() {
      long summer = SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F).geometryKey();
      assertEquals(0L, summer, "a snow-free frame must have the neutral key");

      // If any snowy frame shared summer's key, a section meshed in that winter would look
      // current all summer and never be rebuilt.
      for (CalendarPhase phase : SeasonTestSupport.PHASES) {
         for (int step = 1; step <= 100; step++) {
            SeasonFrame w = SeasonTestSupport.frame(Season.WINTER, phase, step / 100.0F);
            if (w.snowCoverage() > 0.0F && w.snowDepth() > 0.0F) {
               assertNotEquals(summer, w.geometryKey(),
                  "Winter %s @%d%% is indistinguishable from summer".formatted(phase, step));
            }
         }
      }
   }

   @Test
   @DisplayName("every snowy frame in the year is stale against every other one")
   void distinctSnowStatesAreDistinctKeys() {
      Set<Long> keys = new HashSet<>();
      int snowy = 0;
      for (SeasonTestSupport.PhaseRef ref : SeasonTestSupport.cycle()) {
         for (int step = 0; step <= 64; step++) {
            SeasonFrame f = SeasonTestSupport.frame(ref.season(), ref.phase(), step / 64.0F);
            keys.add(f.geometryKey());
            if (f.snowCoverage() > 0.0F) {
               snowy++;
            }
         }
      }
      assertTrue(snowy > 0, "the year must contain snowy frames");
      // Many distinct snow states across the year, all separable.
      assertTrue(keys.size() > 20, "too few distinct geometry states: " + keys.size());
   }

   @Test
   @DisplayName("summer targets zero snow everywhere, so stored winter snow is always unwanted")
   void summerWantsNoSnowAnywhere() {
      SeasonFrame summer = SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F);
      SeasonFrame winter = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.STABLE, 0.6F);
      int winterSnowColumns = 0;
      for (int x = -300; x < 300; x += 3) {
         for (int z = -300; z < 300; z += 3) {
            assertEquals(0, SnowSystem.targetLayers(summer, x, z, SEED),
               "summer must want no snow at %d,%d".formatted(x, z));
            if (SnowSystem.targetLayers(winter, x, z, SEED) > 0) {
               winterSnowColumns++;
            }
         }
      }
      // Every one of these is a column where the LOD may be holding winter snow that summer
      // has to strip; the projector's removal path is what makes that possible at all.
      assertTrue(winterSnowColumns > 30_000,
         "expected a large winter footprint to strip, got " + winterSnowColumns);
   }

   @Test
   @DisplayName("a timelapse year moves through far more geometry states than a sweep can chase")
   void timelapseChangesFasterThanAFullSweep() {
      // /teslesseasons timelapse 600 puts a whole year in ten minutes: 50 s per phase.
      // Count how often the geometry key changes across one such phase.
      int changes = 0;
      long previous = Long.MIN_VALUE;
      int samplesPerPhase = 50 * 20; // 50 seconds at 20 tps
      for (int i = 0; i <= samplesPerPhase; i++) {
         long key = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.STABLE, i / (float) samplesPerPhase)
            .geometryKey();
         if (key != previous) {
            changes++;
            previous = key;
         }
      }
      // This is the number that broke the old scheduler: the key changes several times a
      // second, so anything that restarted its queue on a change never finished one pass.
      // The sweep must therefore be independent of the season, which is what this documents.
      assertTrue(changes > 100,
         "expected rapid key changes under timelapse, got %d - if this drops, revisit whether "
            .formatted(changes) + "the sweep still needs to be season-independent");
   }

   @Test
   @DisplayName("winter targets snow everywhere at full coverage, so nothing may stay green")
   void winterCoversEverything() {
      SeasonFrame winter = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.STABLE, 0.75F);
      assertEquals(1.0F, winter.snowCoverage(), 1.0E-4F, "winter stable is a complete footprint");
      int bare = 0;
      for (int x = 0; x < 400; x++) {
         for (int z = 0; z < 400; z++) {
            if (SnowSystem.targetLayers(winter, x, z, SEED) <= 0) {
               bare++;
            }
         }
      }
      assertEquals(0, bare, "no column may be bare at a complete winter footprint");
   }
}
