package fi.tesles.seasons.mixin.fix064;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.fix064.EndpointChannelCanonicalizer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.chunk.LevelChunk;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(
   targets = {"fi.tesles.seasons.world.SeasonalWorldReconciler"},
   remap = false
)
public abstract class EndpointChannelChunkCanonicalizerMixin {
   @Inject(
      method = {"onChunkLoadMain(Lnet/minecraft/server/level/ServerLevel;Lnet/minecraft/world/level/chunk/LevelChunk;)V"},
      at = {@At("RETURN")},
      remap = false,
      require = 1
   )
   private static void tesles$prioritizeCompletedChannels(ServerLevel level, LevelChunk chunk, CallbackInfo ci) {
      SeasonSnapshot snapshot = SeasonEngine.current();
      if (snapshot != null) {
         EndpointChannelCanonicalizer.prioritizeLoadedChunk(level, chunk, snapshot);
      }
   }
}
