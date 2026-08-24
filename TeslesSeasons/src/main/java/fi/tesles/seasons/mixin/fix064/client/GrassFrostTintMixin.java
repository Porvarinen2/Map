package fi.tesles.seasons.mixin.fix064.client;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.ClientSeasonState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   targets = {"fi.tesles.seasons.client.render.SeasonalColorUtil"},
   remap = false
)
public abstract class GrassFrostTintMixin {
   @Inject(
      method = {"grassColor(I)I"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$frostGrassWithoutBrowning(int biomeColour, CallbackInfoReturnable<Integer> cir) {
      SeasonSnapshot s = ClientSeasonState.get();
      if (s == null) {
         cir.setReturnValue(0xFF000000 | biomeColour & 16777215);
      } else {
         int rgb = biomeColour & 16777215;
         rgb = blend(rgb, 8492127, clamp01(s.autumnColor()) * 0.1F);
         rgb = blend(rgb, 11187868, clamp01(s.groundDormancy()) * 0.2F);
         rgb = blend(rgb, 12765883, clamp01(s.snowCover()) * 0.16F);
         rgb = blend(rgb, 7513183, clamp01(s.springFreshness()) * 0.1F);
         cir.setReturnValue(0xFF000000 | rgb);
      }
   }

   private static int blend(int a, int b, float t) {
      t = clamp01(t);
      int ar = a >>> 16 & 0xFF;
      int ag = a >>> 8 & 0xFF;
      int ab = a & 0xFF;
      int br = b >>> 16 & 0xFF;
      int bg = b >>> 8 & 0xFF;
      int bb = b & 0xFF;
      int r = Math.round(ar + (br - ar) * t);
      int g = Math.round(ag + (bg - ag) * t);
      int bl = Math.round(ab + (bb - ab) * t);
      return r << 16 | g << 8 | bl;
   }

   private static float clamp01(float v) {
      return Math.max(0.0F, Math.min(1.0F, v));
   }
}
