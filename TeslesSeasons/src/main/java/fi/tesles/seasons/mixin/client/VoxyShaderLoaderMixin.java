package fi.tesles.seasons.mixin.client;

import fi.tesles.seasons.client.voxy.VoxyCanonicalVisualPostPatch;
import fi.tesles.seasons.client.voxy.VoxySeasonShaderPatch;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.core.gl.shader.ShaderLoader"},
   remap = false
)
public abstract class VoxyShaderLoaderMixin {
   @Inject(
      method = {"parse"},
      at = {@At("RETURN")},
      cancellable = true,
      remap = false,
      require = 0
   )
   private static void tesles$patchSeasonShaders(String resource, CallbackInfoReturnable<String> cir) {
      String seasonal = VoxySeasonShaderPatch.patch(resource, (String)cir.getReturnValue());
      cir.setReturnValue(VoxyCanonicalVisualPostPatch.patch(resource, seasonal));
   }
}
