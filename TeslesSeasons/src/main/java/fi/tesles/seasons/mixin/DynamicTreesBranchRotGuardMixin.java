package fi.tesles.seasons.mixin;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.compat.DynamicTreesCompat;
import fi.tesles.seasons.world.SeasonalBlockClassifier;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.LevelAccessor;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Pseudo
@Mixin(
   targets = {"com.dtteam.dynamictrees.block.branch.BranchBlock"}
)
public abstract class DynamicTreesBranchRotGuardMixin {
   @Inject(
      method = {"rot"},
      at = {@At("HEAD")},
      cancellable = true,
      require = 0
   )
   private void tesles$protectDormantDeciduousScaffold(LevelAccessor level, BlockPos pos, CallbackInfo ci) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.physicalDeciduousLeafFall && TeslesSeasons.CONFIG.protectDormantDynamicTreeBranches) {
         if (level instanceof ServerLevel serverLevel) {
            if (!(SeasonEngine.current().leafRetention() >= 0.999F)) {
               BlockState state = serverLevel.getBlockState(pos);
               if (SeasonalBlockClassifier.isDynamicBranch(state) && !SeasonalBlockClassifier.isEvergreen(state)) {
                  if (DynamicTreesCompat.findRoot(serverLevel, pos) != null) {
                     ci.cancel();
                  }
               }
            }
         }
      }
   }
}
