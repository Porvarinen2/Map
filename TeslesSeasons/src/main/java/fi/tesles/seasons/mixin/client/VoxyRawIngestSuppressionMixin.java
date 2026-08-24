package fi.tesles.seasons.mixin.client;

import fi.tesles.seasons.client.voxy.VoxySeasonMutationFilter;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.common.world.service.VoxelIngestService"},
   remap = false
)
public abstract class VoxyRawIngestSuppressionMixin {
   @Inject(
      method = {"rawIngest(Lme/cortex/voxy/commonImpl/WorldIdentifier;Lnet/minecraft/world/level/chunk/LevelChunkSection;IIILnet/minecraft/world/level/chunk/DataLayer;Lnet/minecraft/world/level/chunk/DataLayer;)Z"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 0
   )
   private static void tesles$skipSeasonalMutationIngest(CallbackInfoReturnable<Boolean> cir) {
      if (VoxySeasonMutationFilter.consumeRawIngestSuppression()) {
         cir.setReturnValue(false);
      }
   }

   @Inject(
      method = {"rawIngest(Lme/cortex/voxy/common/world/WorldEngine;Lnet/minecraft/world/level/chunk/LevelChunkSection;IIILnet/minecraft/world/level/chunk/DataLayer;Lnet/minecraft/world/level/chunk/DataLayer;)Z"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 0
   )
   private static void tesles$skipSeasonalMutationEngineIngest(CallbackInfoReturnable<Boolean> cir) {
      if (VoxySeasonMutationFilter.consumeRawIngestSuppression()) {
         cir.setReturnValue(false);
      }
   }
}
