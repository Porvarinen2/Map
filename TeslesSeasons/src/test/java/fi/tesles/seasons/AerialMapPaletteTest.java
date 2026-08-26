package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.client.diagnostic.AerialMapPalette;
import fi.tesles.seasons.client.render.SeasonalCategory;
import java.util.HashSet;
import java.util.Set;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * The diagnostic map's colour rules.
 *
 * <p>The maps exist to be read by someone who was not there, in a screenshot, at a glance. That only
 * works if the mapping from world state to pixel is unambiguous, so it is worth pinning: the states
 * that must be told apart have to have distinct colours, and the blend that draws snow depth and the
 * Voxy overlay has to stay inside the channel range.
 */
class AerialMapPaletteTest {
   @Test
   @DisplayName("states a reader must tell apart have distinct colours")
   void categoriesAreDistinguishable() {
      Set<Integer> seen = new HashSet<>();
      for (SeasonalCategory category : new SeasonalCategory[]{
         SeasonalCategory.SEASONAL_SNOW, SeasonalCategory.DECIDUOUS_LEAVES,
         SeasonalCategory.EVERGREEN_LEAVES, SeasonalCategory.FLOWER, SeasonalCategory.MUSHROOM
      }) {
         assertTrue(seen.add(AerialMapPalette.forCategory(category.voxyId())),
            category + " shares a colour with another category");
      }
   }

   @Test
   @DisplayName("the Voxy states are unmistakable for one another")
   void voxyStatesDiffer() {
      assertNotEquals(AerialMapPalette.VOXY_CURRENT, AerialMapPalette.VOXY_STALE);
      assertNotEquals(AerialMapPalette.VOXY_CURRENT, AerialMapPalette.VOXY_HANDOFF);
      assertNotEquals(AerialMapPalette.VOXY_STALE, AerialMapPalette.VOXY_HANDOFF);
   }

   @Test
   @DisplayName("mixing stays in range and hits both endpoints exactly")
   void mixIsWellBehaved() {
      assertEquals(0x000000, AerialMapPalette.mix(0x000000, 0xFFFFFF, 0.0F));
      assertEquals(0xFFFFFF, AerialMapPalette.mix(0x000000, 0xFFFFFF, 1.0F));
      // Out-of-range amounts are clamped, not wrapped: a blend must never produce a wild colour.
      assertEquals(0x000000, AerialMapPalette.mix(0x000000, 0xFFFFFF, -3.0F));
      assertEquals(0xFFFFFF, AerialMapPalette.mix(0x000000, 0xFFFFFF, 9.0F));

      for (float t = 0.0F; t <= 1.0F; t += 0.05F) {
         int mixed = AerialMapPalette.mix(0x2A4A7A, 0xF2F5F8, t);
         for (int shift : new int[]{16, 8, 0}) {
            int channel = mixed >> shift & 0xFF;
            assertTrue(channel >= 0 && channel <= 255, "channel out of range at t=" + t);
         }
      }
   }

   @Test
   @DisplayName("height shading never blows a channel past white")
   void shadeStaysInRange() {
      for (int h = 0; h <= 320; h += 8) {
         int shaded = AerialMapPalette.shade(0xF2F5F8, h, 0, 320);
         for (int shift : new int[]{16, 8, 0}) {
            int channel = shaded >> shift & 0xFF;
            assertTrue(channel >= 0 && channel <= 255, "channel out of range at height " + h);
         }
      }
      // A flat area must not be shaded into nonsense.
      assertEquals(0xF2F5F8, AerialMapPalette.shade(0xF2F5F8, 64, 64, 64));
   }

   @Test
   @DisplayName("ABGR conversion round-trips the channels")
   void abgrConversion() {
      int rgb = 0x123456;
      int abgr = AerialMapPalette.toAbgr(rgb);
      assertEquals(0xFF, abgr >>> 24, "alpha must be opaque");
      assertEquals(0x12, abgr & 0xFF, "red lands in the low byte");
      assertEquals(0x34, abgr >> 8 & 0xFF);
      assertEquals(0x56, abgr >> 16 & 0xFF);
   }
}
