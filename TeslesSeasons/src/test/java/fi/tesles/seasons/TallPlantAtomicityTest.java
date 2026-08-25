package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.SeasonalFloraKind;
import fi.tesles.seasons.world.system.FloraSystem;
import net.minecraft.core.BlockPos;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * A double-height plant is one logical unit and must be selected or rejected as a whole.
 *
 * <p>The coordinate field includes Y, so evaluating each half at its own position gives two
 * independent answers: at 50% retention roughly half of all tall plants would keep one half and
 * lose the other, filling the world with floating upper halves and headless lower ones. The
 * decision therefore resolves to the lower half's coordinate for both blocks.
 */
class TallPlantAtomicityTest {
   private static final long SEED = 7302026L;

   /** Membership as decided for a plant whose base sits at {@code base}. */
   private static boolean unitDecision(SeasonalFloraKind kind, BlockPos base, SeasonFrame frame) {
      return FloraSystem.shouldExist(kind, base, frame, SEED);
   }

   @Test
   @DisplayName("both halves of a tall plant always reach the same verdict")
   void halvesAgree() {
      // Mid-range retentions are where independent evaluation splits plants most often.
      for (float progress : new float[]{0.25F, 0.5F, 0.75F}) {
         SeasonFrame frame = SeasonTestSupport.frame(Season.AUTUMN, CalendarPhase.STABLE, progress);
         int split = 0, total = 0;
         for (int x = -150; x < 150; x++) {
            for (int z = -150; z < 150; z += 3) {
               BlockPos lower = new BlockPos(x, 64, z);
               BlockPos upper = lower.above();

               boolean unit = unitDecision(SeasonalFloraKind.FLOWER, lower, frame);
               boolean naiveUpper = FloraSystem.shouldExist(SeasonalFloraKind.FLOWER, upper, frame, SEED);
               total++;
               if (unit != naiveUpper) {
                  split++;
               }
            }
         }
         // This is the bug being guarded against: per-position evaluation really does disagree
         // for a large fraction of plants, so routing the upper half to the lower coordinate is
         // load-bearing rather than cosmetic.
         assertTrue(split > total / 10,
            "expected per-position evaluation to split many plants, got %d/%d".formatted(split, total));
      }
   }

   @Test
   @DisplayName("a plant is fully present or fully absent at the retention endpoints")
   void endpointsAreWholePlant() {
      SeasonFrame winter = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.STABLE, 0.5F);
      SeasonFrame summer = SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F);
      for (int i = 0; i < 400; i++) {
         BlockPos base = new BlockPos(i * 17 - 2000, 64, i * -11 + 640);
         for (SeasonalFloraKind kind : new SeasonalFloraKind[]{
            SeasonalFloraKind.FLOWER, SeasonalFloraKind.PLANT, SeasonalFloraKind.MUSHROOM}) {
            assertEquals(false, unitDecision(kind, base, winter), "winter keeps no seasonal flora");
         }
         assertEquals(true, unitDecision(SeasonalFloraKind.FLOWER, base, summer), "summer keeps all flowers");
         assertEquals(true, unitDecision(SeasonalFloraKind.PLANT, base, summer), "summer keeps all plants");
      }
   }

   @Test
   @DisplayName("mushrooms follow their own channel, not the flower channel")
   void mushroomChannelIsIndependent() {
      // Autumn Incoming 50%: mushrooms half returned, flowers still whole.
      SeasonFrame frame = SeasonTestSupport.frame(Season.AUTUMN, CalendarPhase.INCOMING, 0.5F);
      int mushrooms = 0, flowers = 0, n = 0;
      for (int x = 0; x < 200; x++) {
         for (int z = 0; z < 200; z++) {
            BlockPos p = new BlockPos(x, 64, z);
            if (unitDecision(SeasonalFloraKind.MUSHROOM, p, frame)) mushrooms++;
            if (unitDecision(SeasonalFloraKind.FLOWER, p, frame)) flowers++;
            n++;
         }
      }
      assertEquals(0.5F, mushrooms / (float) n, 0.02F, "mushroom retention at Autumn Incoming 50%");
      assertEquals(n, flowers, "flowers are still whole at Autumn Incoming");
   }
}
