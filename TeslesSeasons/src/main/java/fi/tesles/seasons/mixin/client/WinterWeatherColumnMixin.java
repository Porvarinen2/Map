package fi.tesles.seasons.mixin.client;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.client.ClientWeatherState;
import fi.tesles.seasons.weather.TeslesWeatherType;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.client.renderer.WeatherEffectRenderer;
import net.minecraft.client.renderer.state.level.WeatherRenderState;
import net.minecraft.world.phys.Vec3;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(
   value = {WeatherEffectRenderer.class},
   priority = 11000
)
public abstract class WinterWeatherColumnMixin {
   @Inject(
      method = {"render"},
      at = {@At("HEAD")},
      cancellable = true
   )
   private void tesles$suppressVanillaWeatherGeometry(Vec3 cameraPos, WeatherRenderState renderState, CallbackInfo ci) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.customWeatherSystem) {
         if (!ClientWeatherState.get().type().isRain()) {
            ci.cancel();
         }
      }
   }

   @Inject(
      method = {"extractRenderState"},
      at = {@At("TAIL")}
   )
   private void tesles$applyCustomWeatherColumns(ClientLevel level, float partialTicks, Vec3 cameraPos, WeatherRenderState renderState, CallbackInfo ci) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.customWeatherSystem) {
         TeslesWeatherType weather = ClientWeatherState.get().type();
         if (!weather.isRain()) {
            renderState.rainColumns.clear();
            renderState.snowColumns.clear();
         } else {
            renderState.snowColumns.clear();
            double keep = Math.max(0.0, Math.min(1.0, ClientWeatherState.get().intensity()));
            if (!(keep >= 0.995)) {
               renderState.rainColumns.removeIf(column -> hash01(column.x(), column.z()) > keep);
            }
         }
      }
   }

   private static double hash01(int x, int z) {
      long h = x * -7046029254386353131L ^ z * -4417276706812531889L;
      h ^= h >>> 30;
      h *= -4658895280553007687L;
      h ^= h >>> 27;
      h *= -7723592293110705685L;
      h ^= h >>> 31;
      return (h >>> 11) * 1.110223E-16F;
   }
}
