package fi.tesles.seasons.mixin.fix064;

import fi.tesles.seasons.world.SeasonalBlockClassifier;
import java.util.Locale;
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
public abstract class LeafClassifierHardeningMixin {
   @Inject(
      method = {"isDeciduousLeaf(Lnet/minecraft/world/level/block/state/BlockState;)Z"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$allDynamicLeavesAreClassified(BlockState state, CallbackInfoReturnable<Boolean> cir) {
      if (tesles$isDynamicLeavesState(state)) {
         cir.setReturnValue(!SeasonalBlockClassifier.isEvergreen(state));
      }
   }

   @Inject(
      method = {"isDynamicDeciduousLeaf(Lnet/minecraft/world/level/block/state/BlockState;)Z"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$allDynamicLeafSubclasses(BlockState state, CallbackInfoReturnable<Boolean> cir) {
      if (tesles$isDynamicLeavesState(state)) {
         cir.setReturnValue(!SeasonalBlockClassifier.isEvergreen(state));
      }
   }

   private static boolean tesles$isDynamicLeavesState(BlockState state) {
      if (state != null && !state.isAir()) {
         try {
            String className = state.getBlock().getClass().getName();
            if (className.startsWith("com.dtteam.dynamictrees.block.leaves.")) {
               return true;
            } else {
               Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
               if (id == null) {
                  return false;
               } else {
                  String namespace = id.getNamespace().toLowerCase(Locale.ROOT);
                  String path = id.getPath().toLowerCase(Locale.ROOT);
                  return "dynamictrees".equals(namespace) && (path.equals("leaves") || path.endsWith("_leaves") || path.startsWith("leaves_"));
               }
            }
         } catch (Throwable var5) {
            return false;
         }
      } else {
         return false;
      }
   }
}
