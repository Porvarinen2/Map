package fi.tesles.seasons.mixin.client;

import com.google.common.collect.UnmodifiableIterator;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.client.voxy.VoxyCategoryDiagnostics;
import fi.tesles.seasons.client.voxy.VoxySeasonCategories;
import it.unimi.dsi.fastutil.objects.Object2IntMap;
import it.unimi.dsi.fastutil.objects.Object2IntOpenHashMap;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.ModifyVariable;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.core.model.ModelFactory"},
   remap = false
)
public abstract class VoxyModelFactoryCategoryMixin {
   @Shadow(
      remap = false
   )
   public abstract void setCustomBlockStateMapping(Object2IntMap<BlockState> var1);

   @Inject(
      method = {"<init>"},
      at = {@At("TAIL")},
      remap = false,
      require = 0
   )
   private void tesles$installBaselineSeasonMapping(CallbackInfo ci) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.voxySeasonRendering) {
         this.setCustomBlockStateMapping(new Object2IntOpenHashMap());
      }
   }

   @ModifyVariable(
      method = {"setCustomBlockStateMapping"},
      at = @At("HEAD"),
      argsOnly = true,
      remap = false,
      require = 0
   )
   private Object2IntMap<BlockState> tesles$addSeasonCategories(Object2IntMap<BlockState> original) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.voxySeasonRendering) {
         Object2IntOpenHashMap<BlockState> result = new Object2IntOpenHashMap();
         if (original != null) {
            result.putAll(original);
         }

         result.defaultReturnValue(original == null ? 0 : original.defaultReturnValue());
         int tagged = 0;
         int preserved = 0;
         int classified = 0;

         for (Block block : BuiltInRegistries.BLOCK) {
            UnmodifiableIterator var8 = block.getStateDefinition().getPossibleStates().iterator();

            while (var8.hasNext()) {
               BlockState state = (BlockState)var8.next();
               int category = VoxySeasonCategories.categoryFor(state);
               if (category != 0) {
                  classified++;
                  int customId = original != null && original.containsKey(state) ? original.getInt(state) : 0;
                  if (!VoxySeasonCategories.canAttachCategory(customId)) {
                     result.put(state, customId);
                     preserved++;
                  } else {
                     result.put(state, VoxySeasonCategories.attachCategory(customId, category));
                     tagged++;
                  }
               }
            }
         }

         VoxyCategoryDiagnostics.update(tagged, preserved, classified);
         TeslesSeasons.LOGGER
            .info(
               "TESLES Voxy seasonal categories attached to {}/{} classified states ({} custom-id conflicts preserved).",
               new Object[]{tagged, classified, preserved}
            );
         return result;
      } else {
         return original;
      }
   }
}
