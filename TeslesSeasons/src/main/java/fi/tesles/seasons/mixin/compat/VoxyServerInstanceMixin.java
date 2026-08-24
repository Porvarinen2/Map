package fi.tesles.seasons.mixin.compat;

import fi.tesles.seasons.compat.VoxyServerBackfillBridge;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Pseudo
@Mixin(
   targets = {"com.dripps.voxyserver.Voxyserver"},
   remap = false
)
public abstract class VoxyServerInstanceMixin {
   @Inject(
      method = {"onInitialize"},
      at = {@At("TAIL")},
      remap = false,
      require = 0
   )
   private void tesles$captureVoxyServer(CallbackInfo ci) {
      VoxyServerBackfillBridge.captureInstance(this);
   }
}
