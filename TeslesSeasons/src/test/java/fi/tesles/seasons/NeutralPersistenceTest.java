package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.system.LeafSystem;
import fi.tesles.seasons.world.system.SnowSystem;
import net.minecraft.core.BlockPos;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Guards the rule that keeps Voxy's LOD database season-neutral.
 *
 * <p>On a dedicated server the client cannot see the server's mutation guard or its restore
 * ledger, so {@code VoxySeasonMutationFilter} has to recognise a seasonal block change from
 * the change itself and keep it out of Voxy's ingest. A seasonal change that slips through is
 * written into the LOD database as permanent terrain, and remeshing can never undo it: that is
 * precisely how old seasons become stuck in the distance.
 *
 * <p>The filter recognises changes by re-evaluating the same deterministic field the server
 * used. These tests pin the two properties that makes possible: the server's decision function
 * is pure and reproducible, and "the new snow depth is exactly the season's target" is a
 * discriminating signal rather than a coin flip.
 */
class NeutralPersistenceTest {
   private static final long SEED = 7302026L;

   @Test
   @DisplayName("the leaf decision is reproducible, so client and server reach the same verdict")
   void leafDecisionIsReproducible() {
      SeasonFrame frame = SeasonTestSupport.frame(Season.AUTUMN, CalendarPhase.STABLE, 0.7F);
      int existing = 0, total = 0;
      for (int x = -200; x < 200; x += 3) {
         for (int y = 60; y < 80; y++) {
            for (int z = -60; z < 60; z += 7) {
               BlockPos pos = new BlockPos(x, y, z);
               boolean first = LeafSystem.shouldExist(pos, frame, SEED);
               // Re-evaluating must give the identical answer: the client's filter depends on
               // it entirely, and a salted/unsalted mismatch here made it near-random once.
               assertEquals(first, LeafSystem.shouldExist(pos, frame, SEED));
               assertEquals(first, LeafSystem.shouldExist(new BlockPos(x, y, z), frame, SEED));
               if (first) existing++;
               total++;
            }
         }
      }
      // Autumn Stable 70% keeps ~30% of leaves; if the field were unsalted or otherwise wrong
      // this ratio would not land near the frame's retention.
      assertEquals(frame.leafRetention(), existing / (float) total, 0.02F,
         "leaf retention must match the frame target");
   }

   @Test
   @DisplayName("leaf decisions at the retention endpoints are absolute")
   void leafEndpointsAreAbsolute() {
      SeasonFrame winter = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.STABLE, 0.5F);
      SeasonFrame summer = SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F);
      for (int i = 0; i < 500; i++) {
         BlockPos pos = new BlockPos(i * 13 - 3000, 64 + (i % 40), i * -7 + 900);
         assertTrue(!LeafSystem.shouldExist(pos, winter, SEED), "no deciduous leaves in winter");
         assertTrue(LeafSystem.shouldExist(pos, summer, SEED), "all deciduous leaves in summer");
      }
    }

   @Test
   @DisplayName("an exact target depth discriminates season snow from player snow")
   void exactDepthIsADiscriminatingSignal() {
      SeasonFrame frame = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.STABLE, 0.54F);

      int seasonRecognised = 0, seasonColumns = 0;
      int playerFalsePositives = 0, playerColumns = 0;

      for (int x = 0; x < 300; x++) {
         for (int z = 0; z < 300; z++) {
            int target = SnowSystem.targetLayers(frame, x, z, SEED);
            if (target <= 0) {
               continue;
            }
            seasonColumns++;
            // What the season itself writes must always be recognised as seasonal.
            if (looksSeasonal(frame, x, z, target)) seasonRecognised++;

            // A player stacking snow by hand: some legal depth chosen independently.
            int playerDepth = 1 + ((x * 31 + z * 17) % 8);
            playerColumns++;
            if (looksSeasonal(frame, x, z, playerDepth)) playerFalsePositives++;
         }
      }

      assertEquals(seasonColumns, seasonRecognised, "season-written depth must always match");
      assertTrue(seasonColumns > 50_000, "sample too small: " + seasonColumns);
      float falseRate = playerFalsePositives / (float) playerColumns;
      assertTrue(falseRate < 0.35F,
         "exact-depth matching is not discriminating enough: %.3f of player placements collide"
            .formatted(falseRate));
   }

   /**
    * The predicate VoxySeasonMutationFilter applies to a snow placement: suppress the ingest
    * only when the new depth is exactly what the current frame asks for at this column.
    */
   private static boolean looksSeasonal(SeasonFrame frame, int x, int z, int newDepth) {
      int target = SnowSystem.targetLayers(frame, x, z, SEED);
      return target > 0 && newDepth == target;
   }

   @Test
   @DisplayName("no snow is targeted outside the snow seasons, so nothing is suppressed there")
   void nothingSuppressedWhenSeasonWantsNoSnow() {
      for (SeasonTestSupport.PhaseRef ref : SeasonTestSupport.cycle()) {
         SeasonFrame frame = SeasonTestSupport.frame(ref.season(), ref.phase(), 0.5F);
         if (frame.snowCoverage() > 0.0F) {
            continue;
         }
         for (int x = 0; x < 120; x++) {
            for (int z = 0; z < 120; z++) {
               assertEquals(0, SnowSystem.targetLayers(frame, x, z, SEED),
                  "%s must target no snow, so player snow is never mistaken for seasonal"
                     .formatted(ref));
            }
         }
      }
   }
}
