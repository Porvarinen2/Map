package fi.tesles.seasons.mixin.fix064;

import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   targets = {"fi.tesles.seasons.world.SeasonalWorldReconciler"},
   remap = false
)
public abstract class GrassBlockIntegrityMixin {
   @Inject(
      method = {"setSeasonBlock(Lnet/minecraft/server/level/ServerLevel;Lnet/minecraft/core/BlockPos;Lnet/minecraft/world/level/block/state/BlockState;I)Z"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$neverReplaceGrass(ServerLevel level, BlockPos pos, BlockState requested, int flags, CallbackInfoReturnable<Boolean> cir) {
      BlockState current = level.getBlockState(pos);
      if (tesles$isGrassIdentity(current)) {
         if (requested == null || requested.getBlock() != current.getBlock()) {
            cir.setReturnValue(false);
         }
      }
   }

   private static boolean tesles$isGrassIdentity(BlockState state) {
      if (state == null || state.isAir()) {
         return false;
      } else if (state.is(Blocks.GRASS_BLOCK)) {
         return true;
      } else {
         try {
            Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
            if (id == null) {
               return false;
            } else {
               String path = id.getPath();
               return path.equals("grass_block") || path.endsWith("_grass_block");
            }
         } catch (Throwable var3) {
            return false;
         }
      }
   }
}
