package fi.tesles.seasons.mixin.fix061;

import fi.tesles.seasons.fix061.SurfaceColumnScatter;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyVariable;

@Mixin(
   targets = {"fi.tesles.seasons.world.SeasonalWorldReconciler"},
   remap = false
)
public abstract class SurfaceColumnScatterMixin {
   @ModifyVariable(
      method = {"reconcileSurfaceColumn(Lfi/tesles/seasons/world/SeasonalWorldReconciler$WorkState;ILfi/tesles/seasons/api/SeasonSnapshot;IZ)I"},
      at = @At("HEAD"),
      argsOnly = true,
      ordinal = 0,
      remap = false,
      require = 1
   )
   private static int tesles$scatterSurfaceProgress(int columnIndex) {
      return SurfaceColumnScatter.permute(columnIndex);
   }
}
