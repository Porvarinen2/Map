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
   @DisplayName("a season with no snow and whole leaves never invalidates a single LOD section")
   void seasonsWithNoSeasonalGeometryNeverRemesh() {
      // The projector edits exactly two things in LOD geometry: snow, and dropped leaves.
      // A frame with neither is interchangeable with every other such frame, and Summer is a
      // whole season of them - not one section may be rebuilt across all of it.
      Set<Long> keys = new HashSet<>();
      for (CalendarPhase phase : SeasonTestSupport.PHASES) {
         for (int i = 0; i <= 400; i++) {
            SeasonFrame f = SeasonTestSupport.frame(Season.SUMMER, phase, i / 400.0F);
            assertEquals(0.0F, f.snowCoverage(), 1.0E-4F, "test premise: summer has no snow");
            assertEquals(1.0F, f.leafRetention(), 1.0E-4F, "test premise: summer keeps its leaves");
            keys.add(f.geometryKey());
         }
      }
      assertEquals(Set.of(0L), keys,
         "summer must be one single geometry state, or Voxy rebuilds for nothing");
   }

   @Test
   @DisplayName("dropping leaves changes the geometry key even with no snow on the ground")
   void leafDropIsGeometryEvenWithoutSnow() {
      // Autumn Stable drops the canopy while the ground is still bare. Those leaves are
      // removed from the LOD mesh rather than discarded in the shader - a discard is invisible
      // to Iris's shadow pass - so the key has to move or the distant canopy would keep its
      // summer geometry, and its shadows, all the way into winter.
      Set<Long> keys = new HashSet<>();
      for (int i = 0; i <= 400; i++) {
         SeasonFrame f = SeasonTestSupport.frame(Season.AUTUMN, CalendarPhase.STABLE, i / 400.0F);
         assertEquals(0.0F, f.snowCoverage(), 1.0E-4F, "test premise: no snow in Autumn Stable");
         keys.add(f.geometryKey());
      }
      assertTrue(keys.size() > 100,
         "leaf drop must move the geometry key; got only %d states".formatted(keys.size()));
      assertTrue(keys.size() <= 300,
         "leaf drop is quantised, so it must not produce a key per sample: " + keys.size());
   }

   @Test
   @DisplayName("a snowy frame with whole leaves never collides with the neutral key")
   void snowyFramesNeverLookNeutral() {
      for (CalendarPhase phase : SeasonTestSupport.PHASES) {
         for (int i = 0; i <= 200; i++) {
            SeasonFrame f = SeasonTestSupport.frame(Season.WINTER, phase, i / 200.0F);
            if (f.snowCoverage() > 0.0F || f.leafRetention() < 0.9999F) {
               assertTrue(f.geometryKey() != 0L,
                  "Winter %s @%d would be served as a snow-free cache hit".formatted(phase, i));
            }
         }
      }
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
