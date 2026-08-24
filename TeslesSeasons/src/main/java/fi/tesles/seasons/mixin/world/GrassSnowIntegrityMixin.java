package fi.tesles.seasons.mixin.world;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.world.system.SnowSystem;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SpreadingSnowyBlock;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin({SpreadingSnowyBlock.class})
public abstract class GrassSnowIntegrityMixin {
   @Inject(
      method = {"randomTick"},
      at = {@At("HEAD")},
      cancellable = true,
      require = 0
   )
   private void tesles$preserveGrassUnderSeasonSnow(BlockState state, ServerLevel level, BlockPos pos, RandomSource random, CallbackInfo ci) {
      if (state.is(Blocks.GRASS_BLOCK)) {
         if (!(SeasonEngine.frame().snowDepth() <= 0.0F)) {
            if (SnowSystem.isSeasonSnow(level.getBlockState(pos.above()))) {
               ci.cancel();
            }
         }
      }
   }
}
