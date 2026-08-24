package fi.tesles.seasons.mixin.fix064.client;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.fix069.ProportionalSeasonModel;
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
public abstract class VoxyPhaseUniformMixin {
   @Unique
   private boolean tesles$resolved;
   @Unique
   private int tesles$snowDepthLocation = -1;
   @Unique
   private int tesles$plantRetentionLocation = -1;

   @Shadow
   public abstract int id();

   @Inject(
      method = {"bind()V"},
      at = {@At("TAIL")},
      remap = false,
      require = 0
   )
   private void tesles$uploadProportionalPhase(CallbackInfo ci) {
      if (!this.tesles$resolved) {
         this.tesles$snowDepthLocation = GL20C.glGetUniformLocation(this.id(), "teslesSnowDepth");
         this.tesles$plantRetentionLocation = GL20C.glGetUniformLocation(this.id(), "teslesPlantRetention");
         this.tesles$resolved = true;
      }

      SeasonSnapshot snapshot = ClientSeasonState.get();
      if (snapshot != null) {
         if (this.tesles$snowDepthLocation >= 0) {
            GL20C.glUniform1f(this.tesles$snowDepthLocation, ProportionalSeasonModel.snowDepthFraction(snapshot));
         }

         if (this.tesles$plantRetentionLocation >= 0) {
            GL20C.glUniform1f(this.tesles$plantRetentionLocation, ProportionalSeasonModel.plantRetention(snapshot));
         }
      }
   }
}
