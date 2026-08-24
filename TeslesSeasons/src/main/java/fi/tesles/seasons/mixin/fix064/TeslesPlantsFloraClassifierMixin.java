package fi.tesles.seasons.mixin.fix064;

import fi.tesles.seasons.world.SeasonalFloraKind;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   targets = {"fi.tesles.seasons.world.SeasonalBlockClassifier"},
   remap = false
)
public abstract class TeslesPlantsFloraClassifierMixin {
   @Inject(
      method = {"floraKind(Lnet/minecraft/world/level/block/state/BlockState;)Lfi/tesles/seasons/world/SeasonalFloraKind;"},
      at = {@At("RETURN")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$allTeslesPlantsAreSeasonFlora(BlockState state, CallbackInfoReturnable<SeasonalFloraKind> cir) {
      if (state != null && !state.isAir() && cir.getReturnValue() == SeasonalFloraKind.NONE) {
         if (state.getFluidState().isEmpty()) {
            try {
               Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
               if (id != null && "teslesplants".equals(id.getNamespace())) {
                  cir.setReturnValue(SeasonalFloraKind.PLANT);
               }
            } catch (Throwable var3) {
            }
         }
      }
   }
}
