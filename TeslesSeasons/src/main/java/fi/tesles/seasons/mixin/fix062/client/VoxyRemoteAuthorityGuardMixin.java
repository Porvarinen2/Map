package fi.tesles.seasons.mixin.fix062.client;

import com.dripps.voxyserver.client.ClientLodSettings;
import me.cortex.voxy.commonImpl.WorldIdentifier;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.commonImpl.VoxyInstance"},
   remap = false
)
public abstract class VoxyRemoteAuthorityGuardMixin {
   @Inject(
      method = {"isIngestEnabled(Lme/cortex/voxy/commonImpl/WorldIdentifier;)Z"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 0
   )
   private void tesles$remoteLodOwnsClientWorld(WorldIdentifier identifier, CallbackInfoReturnable<Boolean> cir) {
      try {
         if (ClientLodSettings.isProtocolOk()) {
            cir.setReturnValue(false);
         }
      } catch (Throwable var4) {
      }
   }
}
