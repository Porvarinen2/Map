package fi.tesles.seasons.mixin.compat;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.compat.VoxyServerMutationGuard;
import net.minecraft.server.level.ServerLevel;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Pseudo
@Mixin(
   targets = {"com.dripps.voxyserver.server.DirtyTracker"},
   remap = false
)
public abstract class VoxyServerDirtyTrackerMixin {
   @Inject(
      method = {"markDirty"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 0
   )
   private void tesles$keepSeasonNeutralLodBase(ServerLevel level, int chunkX, int blockY, int chunkZ, CallbackInfo ci) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.suppressSeasonalVoxyReingest && VoxyServerMutationGuard.isSuppressingAnySeasonalLodMutation()) {
         ci.cancel();
      }
   }
}
