package fi.tesles.seasons.mixin.client;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.render.SeasonalBlockStateModel;
import net.minecraft.client.renderer.block.BlockAndTintGetter;
import net.minecraft.core.BlockPos;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   value = {SeasonalBlockStateModel.class},
   remap = false
)
public abstract class SeasonalBlockStateModelSafetyMixin {
   @Inject(
      method = {"shouldRenderPlantSnow"},
      at = {@At("HEAD")},
      cancellable = true,
      require = 1
   )
   private static void tesles$noFakePlantSnow(BlockPos pos, SeasonSnapshot snapshot, CallbackInfoReturnable<Boolean> cir) {
      cir.setReturnValue(false);
   }

   @Inject(
      method = {"shouldRenderGroundSnow"},
      at = {@At("HEAD")},
      cancellable = true,
      require = 1
   )
   private static void tesles$noFakeGroundSnow(BlockAndTintGetter view, BlockPos pos, CallbackInfoReturnable<Boolean> cir) {
      cir.setReturnValue(false);
   }

   @Redirect(
      method = {"emitQuads"},
      at = @At(
         value = "INVOKE",
         target = "Lfi/tesles/seasons/api/SeasonSnapshot;flowerRetention()F"
      ),
      require = 1
   )
   private float tesles$keepPhysicalFlowersVisible(SeasonSnapshot snapshot) {
      return 1.0F;
   }

   @Redirect(
      method = {"emitQuads"},
      at = @At(
         value = "INVOKE",
         target = "Lfi/tesles/seasons/api/SeasonSnapshot;mushroomRetention()F"
      ),
      require = 1
   )
   private float tesles$keepMushroomsVisible(SeasonSnapshot snapshot) {
      return 1.0F;
   }
}
