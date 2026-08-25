package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.world.SeasonalWorldReconciler;
import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * A chunk's column sweep must cover the whole chunk, whatever the calendar is doing.
 *
 * <p>The sweep order used to be keyed on the season revision, and the cursor was reset to zero
 * whenever that revision changed. During a fast timelapse the revision changed several times per
 * second while any given chunk came up for its turn every couple of seconds, so the cursor was
 * back at zero on nearly every visit: the same opening columns were redone forever and the rest of
 * the chunk was never visited. Only the player's immediate surroundings looked correct, because
 * those are canonicalised in full by a different path.
 */
class ColumnSweepTest {
   @Test
   @DisplayName("one sweep visits all 256 columns exactly once")
   void sweepIsAPermutation() {
      for (int chunkX = -3; chunkX <= 3; chunkX++) {
         for (int chunkZ = -3; chunkZ <= 3; chunkZ++) {
            for (int sweep = 0; sweep < 8; sweep++) {
               Set<Integer> seen = new HashSet<>();
               for (int i = 0; i < 256; i++) {
                  int column = SeasonalWorldReconciler.columnOrder(chunkX, chunkZ, i, sweep);
                  assertTrue(column >= 0 && column < 256, "column out of range: " + column);
                  assertTrue(seen.add(column), "column " + column + " visited twice in one sweep");
               }
               assertEquals(256, seen.size());
            }
         }
      }
   }

   @Test
   @DisplayName("successive sweeps use different orders")
   void sweepsDiffer() {
      // Otherwise a chunk that is repeatedly cut short mid-sweep would always be cut short at the
      // same columns, and those columns would lag a whole season behind the rest of the chunk.
      int differing = 0;
      for (int i = 0; i < 256; i++) {
         if (SeasonalWorldReconciler.columnOrder(4, -7, i, 0) != SeasonalWorldReconciler.columnOrder(4, -7, i, 1)) {
            differing++;
         }
      }
      assertTrue(differing > 128, "sweeps 0 and 1 should visit columns in a substantially different order");
   }

   @Test
   @DisplayName("neighbouring chunks do not sweep in lockstep")
   void chunksDiffer() {
      int differing = 0;
      for (int i = 0; i < 256; i++) {
         if (SeasonalWorldReconciler.columnOrder(0, 0, i, 3) != SeasonalWorldReconciler.columnOrder(1, 0, i, 3)) {
            differing++;
         }
      }
      assertTrue(differing > 128, "adjacent chunks should not advance the same columns together");
   }
}
