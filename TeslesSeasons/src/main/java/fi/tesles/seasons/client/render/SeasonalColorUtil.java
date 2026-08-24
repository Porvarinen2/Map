package fi.tesles.seasons.client.render;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.ClientSeasonState;
import java.util.Locale;
import net.minecraft.client.renderer.block.BlockAndTintGetter;
import net.minecraft.world.level.block.state.BlockState;

public final class SeasonalColorUtil {
   private SeasonalColorUtil() {
   }

   public static boolean isVoxyCapture(BlockAndTintGetter view) {
      String name = view.getClass().getName().toLowerCase(Locale.ROOT);
      return name.contains("voxy");
   }

   public static int foliageColor(BlockState state, int baseColor) {
      SeasonSnapshot snapshot = ClientSeasonState.get();
      if (snapshot == null) {
         return opaque(baseColor);
      } else if (SeasonalClassifier.isEvergreen(state)) {
         int c = blend(baseColor, 7304302, snapshot.groundDormancy() * 0.18F);
         return opaque(c);
      } else {
         int base = baseColor & 16777215;
         int targetAutumn = SeasonalClassifier.autumnLeafRgb(state);
         float autumn = snapshot.autumnColor();
         float initialBlend = 0.22F + autumn * 0.74F;
         int c = blend(base, targetAutumn, initialBlend);
         if (autumn > 0.6F) {
            float unify = (autumn - 0.6F) / 0.4F;
            c = blend(c, targetAutumn, 0.55F * unify);
         }

         c = blend(c, 8551789, snapshot.groundDormancy() * 0.22F);
         c = blend(c, 7318903, snapshot.springFreshness() * 0.16F);
         return opaque(c);
      }
   }

   public static int grassColor(int baseColor) {
      SeasonSnapshot snapshot = ClientSeasonState.get();
      if (snapshot == null) {
         return opaque(baseColor);
      } else {
         int c = baseColor & 16777215;
         c = blend(c, 9142085, snapshot.autumnColor() * 0.36F);
         c = blend(c, 8486741, snapshot.groundDormancy() * 0.48F);
         c = blend(c, 7513423, snapshot.springFreshness() * 0.13F);
         return opaque(c);
      }
   }

   public static int staticPlantMultiplier(SeasonalCategory category) {
      SeasonSnapshot snapshot = ClientSeasonState.get();
      if (snapshot == null) {
         return opaque(16777215);
      } else {
         float autumn = snapshot.autumnColor();
         float dormancy = snapshot.groundDormancy();
         float spring = snapshot.springFreshness();
         int c = 16777215;
         if (category == SeasonalCategory.FLOWER) {
            c = blend(c, 14800311, dormancy * 0.26F);
            c = blend(c, 15125405, autumn * 0.16F);
         } else {
            c = blend(c, 14072184, autumn * 0.3F);
            c = blend(c, 13091167, dormancy * 0.42F);
            c = blend(c, 14677455, spring * 0.1F);
            c = blend(c, 14930645, snapshot.snowCover() * 0.13F);
         }

         return opaque(c);
      }
   }

   public static int groundMultiplier() {
      SeasonSnapshot snapshot = ClientSeasonState.get();
      if (snapshot == null) {
         return opaque(16777215);
      } else {
         int c = 16777215;
         c = blend(c, 14074318, snapshot.autumnColor() * 0.12F);
         c = blend(c, 14208885, snapshot.groundDormancy() * 0.1F);
         return opaque(c);
      }
   }

   public static float flattenAmount(SeasonalCategory category, double noise) {
      SeasonSnapshot snapshot = ClientSeasonState.get();
      if (snapshot == null) {
         return 0.0F;
      } else {
         float cap = category == SeasonalCategory.FLOWER ? 0.55F : 1.0F;
         return (float)(noise * snapshot.groundDormancy() * cap);
      }
   }

   public static int opaque(int color) {
      return 0xFF000000 | color & 16777215;
   }

   public static int blend(int from, int to, float t) {
      t = Math.max(0.0F, Math.min(1.0F, t));
      int fr = from >> 16 & 0xFF;
      int fg = from >> 8 & 0xFF;
      int fb = from & 0xFF;
      int tr = to >> 16 & 0xFF;
      int tg = to >> 8 & 0xFF;
      int tb = to & 0xFF;
      int r = Math.round(fr + (tr - fr) * t);
      int g = Math.round(fg + (tg - fg) * t);
      int b = Math.round(fb + (tb - fb) * t);
      return r << 16 | g << 8 | b;
   }
}
