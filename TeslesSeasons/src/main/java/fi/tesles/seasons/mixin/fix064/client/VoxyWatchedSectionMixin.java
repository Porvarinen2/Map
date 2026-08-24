package fi.tesles.seasons.mixin.fix064.client;

import fi.tesles.seasons.fix064.client.VoxySeasonRemeshScheduler;
import me.cortex.voxy.client.core.rendering.SectionUpdateRouter;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.core.rendering.SectionUpdateRouter"},
   remap = false
)
public abstract class VoxyWatchedSectionMixin {
   @Inject(
      method = {"watch(JI)Z"},
      at = {@At("RETURN")},
      remap = false,
      require = 1
   )
   private void tesles$watch(long position, int types, CallbackInfoReturnable<Boolean> cir) {
      if ((types & 1) != 0) {
         VoxySeasonRemeshScheduler.watch((SectionUpdateRouter)(Object)this, position);
      }
   }

   @Inject(
      method = {"unwatch(JI)Z"},
      at = {@At("RETURN")},
      remap = false,
      require = 1
   )
   private void tesles$unwatch(long position, int types, CallbackInfoReturnable<Boolean> cir) {
      if ((types & 1) != 0) {
         SectionUpdateRouter self = (SectionUpdateRouter)(Object)this;
         if ((self.get(position) & 1) == 0) {
            VoxySeasonRemeshScheduler.unwatch(position);
         }
      }
   }
}
