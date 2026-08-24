package fi.tesles.seasons.client.render;

import net.fabricmc.fabric.api.client.model.loading.v1.ModelLoadingPlugin;
import net.fabricmc.fabric.api.client.model.loading.v1.ModelModifier;
import net.fabricmc.fabric.api.client.model.loading.v1.ModelModifier.AfterBakeBlock;
import net.minecraft.client.renderer.block.dispatch.BlockStateModel;

public final class SeasonalModelLoading {
   private SeasonalModelLoading() {
   }

   public static void register() {
      ModelLoadingPlugin.register(
         context -> context.modifyBlockModelAfterBake()
            .register(
               ModelModifier.WRAP_PHASE,
               (AfterBakeBlock)(model, ctx) -> {
                  SeasonalCategory category = SeasonalClassifier.categoryFor(ctx.state());
                  return (BlockStateModel)(category != SeasonalCategory.GROUND_VEGETATION
                        && category != SeasonalCategory.FLOWER
                        && category != SeasonalCategory.MUSHROOM
                        && category != SeasonalCategory.SEASONAL_GROUND
                        && category != SeasonalCategory.SNOW_OVERLAY_PLANT
                        && category != SeasonalCategory.SNOW_REPLACEABLE_DECOR
                        && category != SeasonalCategory.SEASONAL_SNOW
                     ? model
                     : new SeasonalBlockStateModel(model, ctx.state(), category));
               }
            )
      );
   }
}
