package fi.tesles.seasons.mixin.fix064.client;

import fi.tesles.seasons.client.ClientSeasonState;
import me.cortex.voxy.client.core.rendering.building.BuiltSection;
import me.cortex.voxy.common.world.WorldEngine;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.core.rendering.GeometryCache"},
   remap = false
)
public abstract class VoxySeasonGeometryCacheBypassMixin {
   @Inject(
      method = {"remove(J)Lme/cortex/voxy/client/core/rendering/building/BuiltSection;"},
      at = {@At("RETURN")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private void tesles$rejectStaleSeasonMesh(long position, CallbackInfoReturnable<BuiltSection> cir) {
      BuiltSection cached = (BuiltSection)cir.getReturnValue();
      if (cached != null && ClientSeasonState.get() != null) {
         int lvl = WorldEngine.getLevel(position);
         if (lvl >= 0 && lvl <= 2) {
            cached.free();
            cir.setReturnValue(null);
         }
      }
   }
}
