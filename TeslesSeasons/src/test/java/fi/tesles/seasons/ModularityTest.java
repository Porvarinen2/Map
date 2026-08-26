package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.sector.SeasonRegistry;
import fi.tesles.seasons.sector.SeasonSector;
import fi.tesles.seasons.world.effect.SeasonalEffectContext;
import fi.tesles.seasons.world.effect.SeasonalWorldEffect;
import fi.tesles.seasons.world.effect.SeasonalWorldEffects;
import fi.tesles.seasons.world.effect.WaterFreezeEffect;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * The two extension points, held to their promises.
 *
 * <p>Modularity that is only a matter of file layout is not modularity. What makes a season or a
 * world behaviour replaceable is that swapping one changes what the mod does without changing
 * anything else, and that a badly behaved addition cannot reach past its own boundary. That is
 * what is checked here.
 */
class ModularityTest {
   private static final String TEST_EFFECT = "teslesseasons:test_effect";

   @AfterEach
   void cleanUp() {
      SeasonalWorldEffects.unregister(TEST_EFFECT);
      SeasonalWorldEffects.unregister("teslesseasons:test_other");
   }

   private static SeasonFrame frame(Season season, CalendarPhase phase, float progress) {
      return SeasonTestSupport.frame(season, phase, progress);
   }

   @Test
   @DisplayName("a season can be replaced without touching the director")
   void seasonsAreReplaceable() {
      SeasonSector original = SeasonRegistry.get(Season.WINTER);
      assertNotNull(original);
      SeasonSector replacement = raw -> SeasonFrame.builder(raw.season(), raw.phase(), raw.phaseProgress())
         .snow(0.5F, 0.5F)
         .build();
      try {
         assertSame(original, SeasonRegistry.register(Season.WINTER, replacement));
         assertSame(replacement, SeasonRegistry.get(Season.WINTER));
         // The other three are untouched: replacing one season is not replacing the calendar.
         assertNotNull(SeasonRegistry.get(Season.SUMMER));
      } finally {
         SeasonRegistry.register(Season.WINTER, original);
      }
      assertSame(original, SeasonRegistry.get(Season.WINTER));
   }

   @Test
   @DisplayName("a season module must be registered for every season")
   void everySeasonHasAModule() {
      for (Season season : Season.values()) {
         assertNotNull(SeasonRegistry.get(season), season + " has no module");
      }
      assertThrows(IllegalArgumentException.class, () -> SeasonRegistry.register(Season.WINTER, null));
   }

   @Test
   @DisplayName("effects register, keep their order, and can be replaced by id")
   void effectRegistration() {
      SeasonalWorldEffect first = effect(TEST_EFFECT, f -> true);
      SeasonalWorldEffect other = effect("teslesseasons:test_other", f -> true);
      SeasonalWorldEffects.register(first);
      SeasonalWorldEffects.register(other);

      List<SeasonalWorldEffect> all = SeasonalWorldEffects.all();
      int firstIndex = indexOf(all, TEST_EFFECT);
      int otherIndex = indexOf(all, "teslesseasons:test_other");
      assertTrue(firstIndex >= 0 && otherIndex > firstIndex, "registration order is the run order");

      SeasonalWorldEffect replacement = effect(TEST_EFFECT, f -> true);
      assertSame(first, SeasonalWorldEffects.register(replacement));
      assertSame(replacement, SeasonalWorldEffects.all().get(indexOf(SeasonalWorldEffects.all(), TEST_EFFECT)));
      assertEquals(1, count(SeasonalWorldEffects.all(), TEST_EFFECT), "an id appears once");
   }

   @Test
   @DisplayName("an effect that wants nothing from this frame is not run")
   void inactiveEffectsAreSkipped() {
      SeasonalWorldEffects.register(effect(TEST_EFFECT, f -> f.season() == Season.WINTER));
      assertTrue(contains(SeasonalWorldEffects.active(frame(Season.WINTER, CalendarPhase.STABLE, 0.5F)), TEST_EFFECT));
      assertFalse(contains(SeasonalWorldEffects.active(frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F)), TEST_EFFECT));
   }

   @Test
   @DisplayName("with no effect installed the pass allocates nothing")
   void emptyIsFree() {
      // The common case for most of the year, and it runs per column, so it must not build a list.
      assertSame(SeasonalWorldEffects.active(frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F)),
                 SeasonalWorldEffects.active(frame(Season.AUTUMN, CalendarPhase.STABLE, 0.5F)));
   }

   @Test
   @DisplayName("an effect needs an id")
   void idIsRequired() {
      assertThrows(IllegalArgumentException.class, () -> SeasonalWorldEffects.register(effect("  ", f -> true)));
      assertThrows(IllegalArgumentException.class, () -> SeasonalWorldEffects.register(null));
   }

   @Test
   @DisplayName("the shipped water-freezing effect is active in winter and spring only")
   void waterFreezeWindow() {
      WaterFreezeEffect ice = new WaterFreezeEffect();
      assertTrue(ice.appliesTo(frame(Season.WINTER, CalendarPhase.STABLE, 0.5F)), "freezes in winter");
      assertTrue(ice.appliesTo(frame(Season.SPRING, CalendarPhase.STABLE, 0.5F)), "must give its ice back in spring");
      assertFalse(ice.appliesTo(frame(Season.SUMMER, CalendarPhase.STABLE, 0.5F)), "costs nothing in summer");
      assertEquals(WaterFreezeEffect.ID, ice.id());
   }

   private static SeasonalWorldEffect effect(String id, java.util.function.Predicate<SeasonFrame> active) {
      return new SeasonalWorldEffect() {
         @Override
         public String id() {
            return id;
         }

         @Override
         public boolean appliesTo(SeasonFrame frame) {
            return active.test(frame);
         }

         @Override
         public boolean applyToColumn(SeasonalEffectContext context) {
            return true;
         }
      };
   }

   private static int indexOf(List<SeasonalWorldEffect> effects, String id) {
      for (int i = 0; i < effects.size(); i++) {
         if (id.equals(effects.get(i).id())) {
            return i;
         }
      }
      return -1;
   }

   private static int count(List<SeasonalWorldEffect> effects, String id) {
      int n = 0;
      for (SeasonalWorldEffect effect : effects) {
         if (id.equals(effect.id())) {
            n++;
         }
      }
      return n;
   }

   private static boolean contains(List<SeasonalWorldEffect> effects, String id) {
      return indexOf(effects, id) >= 0;
   }
}
