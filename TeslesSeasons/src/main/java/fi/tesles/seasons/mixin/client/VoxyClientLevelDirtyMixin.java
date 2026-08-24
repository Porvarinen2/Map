package fi.tesles.seasons.mixin.client;

import fi.tesles.seasons.client.voxy.VoxySeasonMutationFilter;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin({ClientLevel.class})
public abstract class VoxyClientLevelDirtyMixin {
   @Inject(
      method = {"setBlocksDirty"},
      at = {@At("HEAD")},
      require = 0
   )
   private void tesles$identifySeasonalMutation(BlockPos pos, BlockState oldState, BlockState newState, CallbackInfo ci) {
      VoxySeasonMutationFilter.prepare(pos, oldState, newState);
   }
}
