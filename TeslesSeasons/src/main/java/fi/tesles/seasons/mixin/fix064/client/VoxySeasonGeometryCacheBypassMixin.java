package fi.tesles.seasons.mixin.fix064.client;

import fi.tesles.seasons.fix064.client.VoxySeasonRemeshScheduler;
import fi.tesles.seasons.sector.SeasonDirector;
import me.cortex.voxy.client.core.rendering.building.BuiltSection;
import me.cortex.voxy.common.world.WorldEngine;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * Refuses to serve LOD geometry that was built under an older season.
 *
 * <p>Voxy's geometry cache is keyed only by section position, so without this a mesh built
 * last winter is a perfectly valid cache hit today. That is the second half of the
 * "old season chunks never disappear" problem: even once the remesh scheduler asks for a
 * rebuild, a cached mesh could be handed back unchanged.
 *
 * <p>Rejection is scoped to the frame's geometry key rather than its full revision: only
 * snow changes what a rebuilt LOD section would contain, so colour and calendar movement
 * serve cache hits normally and Voxy keeps its performance. Keying this on the full revision
 * instead threw away the whole LOD cache every time the calendar advanced.
 */
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
      BuiltSection cached = cir.getReturnValue();
      if (cached == null) {
         return;
      }

      int lvl = WorldEngine.getLevel(position);
      if (lvl < 0 || lvl > 2) {
         return;
      }

      if (VoxySeasonRemeshScheduler.isStale(position, SeasonDirector.currentFrame().geometryKey())) {
         cached.free();
         cir.setReturnValue(null);
      }
   }
}
