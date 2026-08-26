package fi.tesles.seasons.client.diagnostic;

import fi.tesles.seasons.client.render.SeasonalCategory;

/**
 * Colours for the diagnostic maps, and the rules for mixing them.
 *
 * <p>Kept separate from the renderer so the mapping from world state to pixel is one readable table
 * and can be unit-tested without a client. Every colour is 0xRRGGBB.
 *
 * <p>The palette deliberately does not try to look like Minecraft. Its job is to make a wrong state
 * obvious at a glance in a screenshot sent by someone else: seasonal snow reads as near-white,
 * anything the mod could not classify reads as magenta, and a Voxy section holding an old season
 * reads as red. A map that is mostly green and grey is a healthy one.
 */
public final class AerialMapPalette {
   public static final int UNKNOWN = 0xC543C5;
   public static final int VOID = 0x101318;
   public static final int WATER = 0x2A4A7A;
   public static final int ICE = 0x9FC6E8;
   public static final int SNOW = 0xF2F5F8;
   public static final int GRASS = 0x5C8A3C;
   public static final int LEAF = 0x3F6B2E;
   public static final int EVERGREEN = 0x2C4A32;
   public static final int FLOWER = 0xC2A33C;
   public static final int MUSHROOM = 0x8A5A3C;
   public static final int BERRY = 0x9B3A4A;
   public static final int GROUND = 0x6B5B4A;
   public static final int STONE = 0x7A7E85;
   public static final int BUILT = 0x8A7A66;

   /** Voxy overlay: a section whose geometry matches the frame in force. */
   public static final int VOXY_CURRENT = 0x35B36A;
   /** Voxy overlay: a section still holding an older season. This is the failure colour. */
   public static final int VOXY_STALE = 0xD1453C;
   /** Voxy overlay: inside the vanilla render distance, where real blocks are drawn instead. */
   public static final int VOXY_HANDOFF = 0x3C7FD1;

   public static final int GRID_CHUNK = 0x1E2530;
   public static final int GRID_REGION = 0x39465A;
   public static final int PLAYER = 0xFFD34A;
   public static final int PANEL_BG = 0x14181E;
   public static final int PANEL_FG = 0xE6EAF0;
   public static final int PANEL_DIM = 0x8B93A1;

   private AerialMapPalette() {
   }

   /** Base colour for a surface category, before snow and shading. */
   public static int forCategory(int voxyCategory) {
      if (voxyCategory == SeasonalCategory.SEASONAL_SNOW.voxyId()) {
         return SNOW;
      } else if (voxyCategory == SeasonalCategory.DECIDUOUS_LEAVES.voxyId() || (voxyCategory >= 11 && voxyCategory <= 15)) {
         return LEAF;
      } else if (voxyCategory == SeasonalCategory.EVERGREEN_LEAVES.voxyId()) {
         return EVERGREEN;
      } else if (voxyCategory == SeasonalCategory.GROUND_VEGETATION.voxyId()) {
         return GRASS;
      } else if (voxyCategory == SeasonalCategory.FLOWER.voxyId()) {
         return FLOWER;
      } else if (voxyCategory == SeasonalCategory.MUSHROOM.voxyId()) {
         return MUSHROOM;
      } else if (voxyCategory == SeasonalCategory.SEASONAL_GROUND.voxyId()) {
         return GRASS;
      } else if (voxyCategory == SeasonalCategory.FROSTABLE_SURFACE.voxyId()) {
         return GROUND;
      } else if (voxyCategory == SeasonalCategory.SNOW_OVERLAY_PLANT.voxyId()) {
         return FLOWER;
      } else if (voxyCategory == SeasonalCategory.SNOW_REPLACEABLE_DECOR.voxyId()) {
         return GRASS;
      }
      return BUILT;
   }

   /**
    * Blends {@code amount} of {@code b} into {@code a}. Used for snow depth, height shading and
    * the Voxy overlay, all of which are "how much of this on top of that".
    */
   public static int mix(int a, int b, float amount) {
      float t = Math.max(0.0F, Math.min(1.0F, amount));
      int ar = a >> 16 & 0xFF, ag = a >> 8 & 0xFF, ab = a & 0xFF;
      int br = b >> 16 & 0xFF, bg = b >> 8 & 0xFF, bb = b & 0xFF;
      int r = Math.round(ar + (br - ar) * t);
      int g = Math.round(ag + (bg - ag) * t);
      int bl = Math.round(ab + (bb - ab) * t);
      return r << 16 | g << 8 | bl;
   }

   /**
    * Height shading: a relief cue so terrain shape is readable.
    *
    * <p>Without it a map of a forest is one flat green rectangle and nothing about the landscape can
    * be recognised, which matters when the point is to say "look at this spot".
    */
   public static int shade(int colour, int height, int minHeight, int maxHeight) {
      if (maxHeight <= minHeight) {
         return colour;
      }
      float t = (height - minHeight) / (float) (maxHeight - minHeight);
      float factor = 0.72F + 0.48F * t;
      int r = Math.min(255, Math.round((colour >> 16 & 0xFF) * factor));
      int g = Math.min(255, Math.round((colour >> 8 & 0xFF) * factor));
      int b = Math.min(255, Math.round((colour & 0xFF) * factor));
      return r << 16 | g << 8 | b;
   }

   /** ABGR, which is what NativeImage stores. */
   public static int toAbgr(int rgb) {
      return 0xFF000000 | (rgb & 0xFF) << 16 | (rgb & 0xFF00) | (rgb >> 16 & 0xFF);
   }
}
