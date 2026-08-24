package fi.tesles.seasons.mixin.fix071.client;

import fi.tesles.seasons.client.render.SeasonalCategory;
import fi.tesles.seasons.client.render.SeasonalClassifier;
import fi.tesles.seasons.world.SeasonalFloraKind;
import fi.tesles.seasons.world.system.TeslesPlantsAdapter;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   value = {SeasonalClassifier.class},
   priority = 1100,
   remap = false
)
public abstract class TeslesPlantsMushroomCategoryMixin {
   @Inject(
      method = {"categoryFor"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false
   )
   private static void tesles$exactMushroomCategory(BlockState state, CallbackInfoReturnable<SeasonalCategory> cir) {
      if (state != null && TeslesPlantsAdapter.kind(state) == SeasonalFloraKind.MUSHROOM) {
         cir.setReturnValue(SeasonalCategory.MUSHROOM);
      }
   }
}
