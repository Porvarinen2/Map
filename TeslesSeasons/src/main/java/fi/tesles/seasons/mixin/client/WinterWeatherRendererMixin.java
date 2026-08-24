package fi.tesles.seasons.mixin.client;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.ClientWeatherState;
import fi.tesles.seasons.weather.TeslesWeatherType;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.biome.Biome.Precipitation;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   value = {ClientLevel.class},
   priority = 11000
)
public abstract class WinterWeatherRendererMixin {
   @Inject(
      method = {"getPrecipitationAt"},
      at = {@At("HEAD")},
      cancellable = true
   )
   private void tesles$customRenderedPrecipitation(BlockPos pos, CallbackInfoReturnable<Precipitation> cir) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.customWeatherSystem) {
         TeslesWeatherType weather = ClientWeatherState.get().type();
         cir.setReturnValue(weather.isRain() ? Precipitation.RAIN : Precipitation.NONE);
      } else if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.seasonalSnow) {
         SeasonSnapshot state = ClientSeasonState.get();
         if (state.season() == Season.WINTER || state.snowCover() >= 0.35F) {
            cir.setReturnValue(Precipitation.SNOW);
         }
      }
   }
}
