package fi.tesles.seasons.mixin.fix064;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.fix069.ProportionalSeasonModel;
import fi.tesles.seasons.world.SeasonalFloraKind;
import fi.tesles.seasons.world.SeasonalWorldReconciler;
import net.minecraft.core.BlockPos;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   targets = {"fi.tesles.seasons.world.SeasonalWorldReconciler"},
   remap = false
)
public abstract class FloraSnowSwapMixin {
   @Inject(
      method = {"floraShouldExist(Lfi/tesles/seasons/world/SeasonalFloraKind;Lnet/minecraft/core/BlockPos;Lfi/tesles/seasons/api/SeasonSnapshot;Z)Z"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$literalPlantRetention(
      SeasonalFloraKind kind, BlockPos pos, SeasonSnapshot snapshot, boolean snowOccupiesColumn, CallbackInfoReturnable<Boolean> cir
   ) {
      if (snowOccupiesColumn) {
         cir.setReturnValue(false);
      } else {
         if (kind == SeasonalFloraKind.PLANT) {
            float threshold = ProportionalSeasonModel.plantRetention(snapshot);
            cir.setReturnValue(SeasonalWorldReconciler.positionNoise(pos, snapshot.visualSeed()) <= threshold);
         }
      }
   }
}
