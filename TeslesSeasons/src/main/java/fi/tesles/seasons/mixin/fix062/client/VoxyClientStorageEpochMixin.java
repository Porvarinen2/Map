package fi.tesles.seasons.mixin.fix062.client;

import java.nio.file.Path;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.VoxyClientInstance"},
   remap = false
)
public abstract class VoxyClientStorageEpochMixin {
   @Inject(
      method = {"getBasePath()Ljava/nio/file/Path;"},
      at = {@At("RETURN")},
      cancellable = true,
      remap = false,
      require = 0
   )
   private static void tesles$seasonNeutralClientCache(CallbackInfoReturnable<Path> cir) {
      Path base = (Path)cir.getReturnValue();
      if (base != null) {
         cir.setReturnValue(base.resolve("tesles-seasons-neutral-v9"));
      }
   }
}
