package fi.tesles.seasons.mixin;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.world.SeasonalBlockClassifier;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.LevelAccessor;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"com.dtteam.dynamictrees.block.leaves.DynamicLeavesBlock"}
)
public abstract class DynamicTreesLeafTickMixin {
   @Inject(
      method = {"age"},
      at = {@At("HEAD")},
      cancellable = true,
      require = 0
   )
   private void tesles$holdSeasonalLeafSpread(
      LevelAccessor level, BlockPos pos, BlockState state, RandomSource random, boolean rapid, CallbackInfoReturnable<Integer> cir
   ) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.physicalDeciduousLeafFall && TeslesSeasons.CONFIG.suppressDormantDynamicTreeLeafSpread) {
         if (level instanceof ServerLevel) {
            if (SeasonalBlockClassifier.isDynamicDeciduousLeaf(state)) {
               if (SeasonEngine.current().leafRetention() < 0.999F) {
                  cir.setReturnValue(0);
               }
            }
         }
      }
   }
}
