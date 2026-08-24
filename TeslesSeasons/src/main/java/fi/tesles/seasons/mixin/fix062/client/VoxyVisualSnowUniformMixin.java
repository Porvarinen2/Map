package fi.tesles.seasons.mixin.fix062.client;

import fi.tesles.seasons.fix062.client.VoxyVisualSnowState;
import org.lwjgl.opengl.GL20C;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.core.gl.shader.Shader"},
   remap = false,
   priority = 900
)
public abstract class VoxyVisualSnowUniformMixin {
   @Unique
   private boolean tesles$visualSnowResolved;
   @Unique
   private int tesles$visualSnowLocation = -1;

   @Shadow
   public abstract int id();

   @Inject(
      method = {"bind()V"},
      at = {@At("TAIL")},
      remap = false,
      require = 0
   )
   private void tesles$uploadMaterializedSnow(CallbackInfo ci) {
      if (!this.tesles$visualSnowResolved) {
         this.tesles$visualSnowLocation = GL20C.glGetUniformLocation(this.id(), "teslesVisualSnowCover");
         this.tesles$visualSnowResolved = true;
      }

      if (this.tesles$visualSnowLocation >= 0) {
         GL20C.glUniform1f(this.tesles$visualSnowLocation, VoxyVisualSnowState.value());
      }
   }
}
