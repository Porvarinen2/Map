package fi.tesles.seasons.mixin.client;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.client.ClientWeatherState;
import fi.tesles.seasons.weather.TeslesWeatherType;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.world.level.Level;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   value = {Level.class},
   priority = 12000
)
public abstract class CustomWeatherRainStrengthMixin {
   @Inject(
      method = {"getRainLevel"},
      at = {@At("HEAD")},
      cancellable = true
   )
   private void tesles$suppressVanillaRainStrength(float partialTick, CallbackInfoReturnable<Float> cir) {
      if ((Object)this instanceof ClientLevel) {
         if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.customWeatherSystem) {
            TeslesWeatherType weather = ClientWeatherState.get().type();
            if (!weather.isRain()) {
               cir.setReturnValue(0.0F);
            }
         }
      }
   }
}
