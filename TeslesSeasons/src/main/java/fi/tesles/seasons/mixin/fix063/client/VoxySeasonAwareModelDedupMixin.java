package fi.tesles.seasons.mixin.fix063.client;

import fi.tesles.seasons.client.voxy.VoxySeasonCategories;
import me.cortex.voxy.client.core.model.ColourDepthTextureData;
import net.minecraft.client.renderer.chunk.ChunkSectionLayer;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.ModifyArg;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.core.model.ModelFactory"},
   remap = false,
   priority = 900
)
public abstract class VoxySeasonAwareModelDedupMixin {
   @Unique
   private static final ThreadLocal<Integer> TESLES_CATEGORY = ThreadLocal.withInitial(() -> 0);

   @Inject(
      method = {"processTextureBakeResult(ILnet/minecraft/world/level/block/state/BlockState;[Lme/cortex/voxy/client/core/model/ColourDepthTextureData;ZZLnet/minecraft/client/renderer/chunk/ChunkSectionLayer;)Lme/cortex/voxy/client/core/model/ModelFactory$ModelBakeResultUpload;"},
      at = {@At("HEAD")},
      remap = false,
      require = 1
   )
   private void tesles$captureSeasonCategory(
      int blockId,
      BlockState state,
      ColourDepthTextureData[] textures,
      boolean shaded,
      boolean darkened,
      ChunkSectionLayer layer,
      CallbackInfoReturnable<?> cir
   ) {
      int category = 0;

      try {
         category = VoxySeasonCategories.categoryFor(state);
      } catch (Throwable var10) {
      }

      TESLES_CATEGORY.set(category);
   }

   @ModifyArg(
      method = {"processTextureBakeResult(ILnet/minecraft/world/level/block/state/BlockState;[Lme/cortex/voxy/client/core/model/ColourDepthTextureData;ZZLnet/minecraft/client/renderer/chunk/ChunkSectionLayer;)Lme/cortex/voxy/client/core/model/ModelFactory$ModelBakeResultUpload;"},
      at = @At(
         value = "INVOKE",
         target = "Lme/cortex/voxy/client/core/model/ModelFactory$ModelEntry;<init>([Lme/cortex/voxy/client/core/model/ColourDepthTextureData;II)V"
      ),
      index = 2,
      remap = false,
      require = 1
   )
   private int tesles$separateSeasonCategoryInDedupKey(int tintKey) {
      int category = TESLES_CATEGORY.get();
      return tintKey == -1 && category > 0 ? category : tintKey;
   }

   @Inject(
      method = {"processTextureBakeResult(ILnet/minecraft/world/level/block/state/BlockState;[Lme/cortex/voxy/client/core/model/ColourDepthTextureData;ZZLnet/minecraft/client/renderer/chunk/ChunkSectionLayer;)Lme/cortex/voxy/client/core/model/ModelFactory$ModelBakeResultUpload;"},
      at = {@At("RETURN")},
      remap = false,
      require = 1
   )
   private void tesles$clearSeasonCategory(
      int blockId,
      BlockState state,
      ColourDepthTextureData[] textures,
      boolean shaded,
      boolean darkened,
      ChunkSectionLayer layer,
      CallbackInfoReturnable<?> cir
   ) {
      TESLES_CATEGORY.remove();
   }
}
