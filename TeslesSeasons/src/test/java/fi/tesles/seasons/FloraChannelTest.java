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
 * Each flora category is a real, independent channel.
 *
 * <p>The specification lists FLOWER, GROUND_PLANT, MUSHROOM and BERRY_BUSH as separate
 * categories, each with its own retention channel and its own field salt. A channel that
 * exists on the frame but that nothing reads is worse than no channel at all: it looks
 * implemented, and the category silently follows some other channel's season.
 */
class FloraChannelTest {
   private static final long SEED = 7302026L;

   private static float fraction(SeasonalFloraKind kind, SeasonFrame frame) {
      int kept = 0, n = 0;
      for (int x = 0; x < 260; x++) {
         for (int z = 0; z < 260; z++) {
            if (FloraSystem.shouldExist(kind, new BlockPos(x, 64, z), frame, SEED)) {
               kept++;
            }
            n++;
         }
      }
      return kept / (float) n;
   }

   @Test
   @DisplayName("every category tracks its own frame channel")
   void categoriesTrackTheirOwnChannel() {
      // Autumn Stable 60%: flowers falling, ground plants still whole, mushrooms at full,
      // berries following the flower-like decline. Four channels, four different values.
      SeasonFrame f = SeasonTestSupport.frame(Season.AUTUMN, CalendarPhase.STABLE, 0.60F);
      assertEquals(f.flowerRetention(), fraction(SeasonalFloraKind.FLOWER, f), 0.02F, "flowers");
      assertEquals(f.plantRetention(), fraction(SeasonalFloraKind.PLANT, f), 0.02F, "ground plants");
      assertEquals(f.mushroomRetention(), fraction(SeasonalFloraKind.MUSHROOM, f), 0.02F, "mushrooms");
      assertEquals(f.berryRetention(), fraction(SeasonalFloraKind.BERRY, f), 0.02F, "berries");
   }

   @Test
   @DisplayName("berries are absent all winter and return across spring")
   void berryContract() {
      for (CalendarPhase phase : SeasonTestSupport.PHASES) {
         for (float p : SeasonTestSupport.CHECKPOINTS) {
            assertEquals(0.0F, SeasonTestSupport.frame(Season.WINTER, phase, p).berryRetention(), 1.0E-4F,
               "no wild berry bushes in Winter " + phase + " @" + p);
         }
      }
      // Spring restores them continuously and Summer is whole.
      assertEquals(0.0F, SeasonTestSupport.frame(Season.SPRING, CalendarPhase.INCOMING, 0.0F).berryRetention(), 1.0E-4F);
      assertEquals(1.0F, SeasonTestSupport.frame(Season.SPRING, CalendarPhase.OUTGOING, 1.0F).berryRetention(), 1.0E-4F);
      assertEquals(1.0F, SeasonTestSupport.frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F).berryRetention(), 1.0E-4F);
   }

   @Test
   @DisplayName("categories at equal retention still select different coordinates")
   void saltsAreIndependentBetweenCategories() {
      // Spring Stable: flowers, plants and berries all sit on the same retention value. If they
      // shared a salt they would pick the identical coordinates and reappear in lockstep, which
      // reads as a single flickering layer rather than a world waking up.
      SeasonFrame f = SeasonTestSupport.frame(Season.SPRING, CalendarPhase.STABLE, 0.5F);
      assertEquals(f.flowerRetention(), f.plantRetention(), 1.0E-4F, "test premise: equal retention");
      assertEquals(f.flowerRetention(), f.berryRetention(), 1.0E-4F, "test premise: equal retention");

      int flowerOnly = 0, berryOnly = 0, n = 0;
      for (int x = 0; x < 200; x++) {
         for (int z = 0; z < 200; z++) {
            BlockPos pos = new BlockPos(x, 64, z);
            boolean flower = FloraSystem.shouldExist(SeasonalFloraKind.FLOWER, pos, f, SEED);
            boolean plant = FloraSystem.shouldExist(SeasonalFloraKind.PLANT, pos, f, SEED);
            boolean berry = FloraSystem.shouldExist(SeasonalFloraKind.BERRY, pos, f, SEED);
            if (flower != plant) flowerOnly++;
            if (flower != berry) berryOnly++;
            n++;
         }
      }
      assertTrue(flowerOnly > n / 5, "flower and plant salts are correlated: only %d/%d differ".formatted(flowerOnly, n));
      assertTrue(berryOnly > n / 5, "flower and berry salts are correlated: only %d/%d differ".formatted(berryOnly, n));
   }

   @Test
   @DisplayName("winter removes every seasonal flora category")
   void winterClearsAllCategories() {
      SeasonFrame winter = SeasonTestSupport.frame(Season.WINTER, CalendarPhase.STABLE, 0.5F);
      for (SeasonalFloraKind kind : new SeasonalFloraKind[]{
         SeasonalFloraKind.FLOWER, SeasonalFloraKind.PLANT,
         SeasonalFloraKind.MUSHROOM, SeasonalFloraKind.BERRY}) {
         assertEquals(0.0F, fraction(kind, winter), 1.0E-4F, kind + " must be gone in winter");
      }
   }
}
