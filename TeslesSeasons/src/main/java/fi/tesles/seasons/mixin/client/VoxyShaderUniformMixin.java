package fi.tesles.seasons.mixin.client;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.voxy.VoxyShaderDiagnostics;
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
   remap = false
)
public abstract class VoxyShaderUniformMixin {
   @Unique
   private boolean tesles$resolved;
   @Unique
   private int tesles$autumn = Integer.MIN_VALUE;
   @Unique
   private int tesles$dormancy = Integer.MIN_VALUE;
   @Unique
   private int tesles$leafRetention = Integer.MIN_VALUE;
   @Unique
   private int tesles$flowerRetention = Integer.MIN_VALUE;
   @Unique
   private int tesles$mushroomRetention = Integer.MIN_VALUE;
   @Unique
   private int tesles$snow = Integer.MIN_VALUE;
   @Unique
   private int tesles$spring = Integer.MIN_VALUE;
   @Unique
   private int tesles$seed = Integer.MIN_VALUE;
   @Unique
   private int tesles$blendStart = Integer.MIN_VALUE;
   @Unique
   private int tesles$blendEnd = Integer.MIN_VALUE;
   @Unique
   private float tesles$lastAutumn = Float.NaN;
   @Unique
   private float tesles$lastDormancy = Float.NaN;
   @Unique
   private float tesles$lastLeafRetention = Float.NaN;
   @Unique
   private float tesles$lastFlowerRetention = Float.NaN;
   @Unique
   private float tesles$lastMushroomRetention = Float.NaN;
   @Unique
   private float tesles$lastSnow = Float.NaN;
   @Unique
   private float tesles$lastSpring = Float.NaN;
   @Unique
   private int tesles$lastSeed = Integer.MIN_VALUE;
   @Unique
   private float tesles$lastBlendStart = Float.NaN;
   @Unique
   private float tesles$lastBlendEnd = Float.NaN;

   @Shadow(
      remap = false
   )
   public abstract int id();

   @Inject(
      method = {"bind"},
      at = {@At("TAIL")},
      remap = false
   )
   private void tesles$uploadSeasonState(CallbackInfo ci) {
      if (!this.tesles$resolved) {
         int program = this.id();
         this.tesles$autumn = GL20C.glGetUniformLocation(program, "teslesAutumn");
         this.tesles$dormancy = GL20C.glGetUniformLocation(program, "teslesDormancy");
         this.tesles$leafRetention = GL20C.glGetUniformLocation(program, "teslesLeafRetention");
         this.tesles$flowerRetention = GL20C.glGetUniformLocation(program, "teslesFlowerRetention");
         this.tesles$mushroomRetention = GL20C.glGetUniformLocation(program, "teslesMushroomRetention");
         this.tesles$snow = GL20C.glGetUniformLocation(program, "teslesSnowCover");
         this.tesles$spring = GL20C.glGetUniformLocation(program, "teslesSpringFresh");
         this.tesles$seed = GL20C.glGetUniformLocation(program, "teslesVisualSeed");
         this.tesles$blendStart = GL20C.glGetUniformLocation(program, "teslesVoxyBlendStart");
         this.tesles$blendEnd = GL20C.glGetUniformLocation(program, "teslesVoxyBlendEnd");
         int resolvedCount = 0;

         for (int location : new int[]{
            this.tesles$autumn,
            this.tesles$dormancy,
            this.tesles$leafRetention,
            this.tesles$flowerRetention,
            this.tesles$mushroomRetention,
            this.tesles$snow,
            this.tesles$spring,
            this.tesles$seed,
            this.tesles$blendStart,
            this.tesles$blendEnd
         }) {
            if (location >= 0) {
               resolvedCount++;
            }
         }

         VoxyShaderDiagnostics.markUniformsResolved(resolvedCount);
         this.tesles$resolved = true;
      }

      SeasonSnapshot state = ClientSeasonState.get();
      if (this.tesles$autumn >= 0 && state.autumnColor() != this.tesles$lastAutumn) {
         GL20C.glUniform1f(this.tesles$autumn, state.autumnColor());
         this.tesles$lastAutumn = state.autumnColor();
      }

      if (this.tesles$dormancy >= 0 && state.groundDormancy() != this.tesles$lastDormancy) {
         GL20C.glUniform1f(this.tesles$dormancy, state.groundDormancy());
         this.tesles$lastDormancy = state.groundDormancy();
      }

      if (this.tesles$leafRetention >= 0 && state.leafRetention() != this.tesles$lastLeafRetention) {
         GL20C.glUniform1f(this.tesles$leafRetention, state.leafRetention());
         this.tesles$lastLeafRetention = state.leafRetention();
      }

      if (this.tesles$flowerRetention >= 0 && state.flowerRetention() != this.tesles$lastFlowerRetention) {
         GL20C.glUniform1f(this.tesles$flowerRetention, state.flowerRetention());
         this.tesles$lastFlowerRetention = state.flowerRetention();
      }

      if (this.tesles$mushroomRetention >= 0 && state.mushroomRetention() != this.tesles$lastMushroomRetention) {
         GL20C.glUniform1f(this.tesles$mushroomRetention, state.mushroomRetention());
         this.tesles$lastMushroomRetention = state.mushroomRetention();
      }

      if (this.tesles$snow >= 0 && state.snowCover() != this.tesles$lastSnow) {
         GL20C.glUniform1f(this.tesles$snow, state.snowCover());
         this.tesles$lastSnow = state.snowCover();
      }

      if (this.tesles$spring >= 0 && state.springFreshness() != this.tesles$lastSpring) {
         GL20C.glUniform1f(this.tesles$spring, state.springFreshness());
         this.tesles$lastSpring = state.springFreshness();
      }

      float blendStart = TeslesSeasons.CONFIG == null ? 96.0F : (float)TeslesSeasons.CONFIG.voxySnowBlendStartBlocks;
      float blendEnd = TeslesSeasons.CONFIG == null ? 384.0F : (float)TeslesSeasons.CONFIG.voxySnowBlendEndBlocks;
      if (this.tesles$blendStart >= 0 && blendStart != this.tesles$lastBlendStart) {
         GL20C.glUniform1f(this.tesles$blendStart, blendStart);
         this.tesles$lastBlendStart = blendStart;
      }

      if (this.tesles$blendEnd >= 0 && blendEnd != this.tesles$lastBlendEnd) {
         GL20C.glUniform1f(this.tesles$blendEnd, blendEnd);
         this.tesles$lastBlendEnd = blendEnd;
      }

      int seed = (int)state.visualSeed();
      if (this.tesles$seed >= 0 && seed != this.tesles$lastSeed) {
         GL20C.glUniform1i(this.tesles$seed, seed);
         this.tesles$lastSeed = seed;
      }

      VoxyShaderDiagnostics.markUniformBind();
   }
}
