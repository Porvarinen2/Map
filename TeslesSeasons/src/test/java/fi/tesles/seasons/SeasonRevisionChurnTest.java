package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Bounds how often the world is told to redo itself.
 *
 * <p>A revision bump means the server re-queues every loaded chunk and the client invalidates
 * and rebuilds every Voxy LOD section. The calendar advances continuously and is sampled every
 * 30 seconds by default, so comparing raw floats made every single sample look like a change:
 * the entire LOD set was rebuilt twice a minute, all year, which showed up in game as LOD
 * quality flickering between detail levels and a collapse to ~20 fps.
 *
 * <p>These tests fix the sampling rate at the real one and assert the resulting work rate.
 */
class SeasonRevisionChurnTest {
   /** Default TeslesSeasonsConfig.calendarRefreshSeconds. */
   private static final int REFRESH_SECONDS = 30;
   private static final int PHASE_SECONDS = 7 * 24 * 3600;
   private static final int SAMPLES_PER_PHASE = PHASE_SECONDS / REFRESH_SECONDS; // 20160

   /** Distinct target sets a phase passes through when sampled at the real refresh rate. */
   private static int distinctTargets(Season season, CalendarPhase phase) {
      int changes = 0;
      SeasonFrame previous = null;
      for (int i = 0; i <= SAMPLES_PER_PHASE; i++) {
         SeasonFrame f = SeasonTestSupport.frame(season, phase, i / (float) SAMPLES_PER_PHASE);
         if (previous == null || !previous.sameTargets(f)) {
            changes++;
            previous = f;
         }
      }
      return changes;
   }

   @Test
   @DisplayName("a phase never asks the world to redo itself more than a few hundred times")
   void worldPassesPerPhaseAreBounded() {
      for (SeasonTestSupport.PhaseRef ref : SeasonTestSupport.cycle()) {
         int changes = distinctTargets(ref.season(), ref.phase());
         // 1/256 quantisation over the widest-moving phase gives a few hundred steps; the
         // unquantised comparison gave one per sample, i.e. 20160.
         assertTrue(changes <= 600,
            "%s would trigger %d full world passes per phase (one every %.1f minutes)"
               .formatted(ref, changes, PHASE_SECONDS / 60.0 / changes));
      }
   }

   @Test
   @DisplayName("a stable phase with no moving target never bumps a revision at all")
   void stablePhaseIsFree() {
      // Summer Stable is the canonical do-nothing phase: every target is pinned.
      assertEquals(1, distinctTargets(Season.SUMMER, CalendarPhase.STABLE),
         "Summer Stable must not schedule any world work");
   }

   @Test
   @DisplayName("snow-free seasons never invalidate a single Voxy LOD section")
   void snowFreeSeasonsNeverRemesh() {
      Set<Long> keys = new HashSet<>();
      for (SeasonTestSupport.PhaseRef ref : SeasonTestSupport.cycle()) {
         if (ref.season() == Season.WINTER) {
            continue;
         }
         for (int i = 0; i <= 400; i++) {
            SeasonFrame f = SeasonTestSupport.frame(ref.season(), ref.phase(), i / 400.0F);
            if (f.snowCoverage() <= 0.0F) {
               keys.add(f.geometryKey());
            }
         }
      }
      assertEquals(Set.of(0L), keys,
         "every snow-free frame must share one geometry key, or Voxy rebuilds for nothing");
   }

   @Test
   @DisplayName("LOD rebuild passes across a whole winter stay in the low hundreds")
   void winterRemeshPassesAreBounded() {
      Set<Long> keys = new HashSet<>();
      for (CalendarPhase phase : SeasonTestSupport.PHASES) {
         for (int i = 0; i <= SAMPLES_PER_PHASE; i++) {
            keys.add(SeasonTestSupport.frame(Season.WINTER, phase, i / (float) SAMPLES_PER_PHASE)
               .geometryKey());
         }
      }
      // Three winter phases at 1/256 depth granularity, plus the shared snow-free key.
      assertTrue(keys.size() <= 800,
         "winter would rebuild the Voxy LOD set %d times".formatted(keys.size()));
      assertTrue(keys.size() >= 8,
         "winter must still advance snow depth, got only %d distinct geometries".formatted(keys.size()));
   }

   @Test
   @DisplayName("colour-only movement never invalidates LOD geometry")
   void colourMovementDoesNotRemesh() {
      // Summer Outgoing runs the autumn colour transform 0 -> 100% with no snow at all.
      // Colour reaches Voxy as a uniform, so geometry must not be touched.
      Set<Long> keys = new HashSet<>();
      for (int i = 0; i <= 400; i++) {
         keys.add(SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.OUTGOING, i / 400.0F)
            .geometryKey());
      }
      assertEquals(Set.of(0L), keys, "autumn colour must not rebuild LOD geometry");
   }

   @Test
   @DisplayName("progress alone is not a target: it must not schedule work")
   void rawProgressIsNotATarget() {
      // Two samples 30 seconds apart inside a pinned phase.
      SeasonFrame a = SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.STABLE, 0.500000F);
      SeasonFrame b = SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.STABLE, 0.500049F);
      assertTrue(a.sameTargets(b), "a 30-second clock tick must not look like a season change");
      assertTrue(a.progress() != b.progress(), "progress itself should still advance");
   }
}
