package fi.tesles.seasons.mixin.fix064;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.fix064.EndpointChannelCanonicalizer;
import fi.tesles.seasons.fix069.ProportionalSeasonModel;
import fi.tesles.seasons.world.SeasonalWorldReconciler;
import net.minecraft.server.MinecraftServer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(
   targets = {"fi.tesles.seasons.world.SeasonalWorldReconciler"},
   remap = false
)
public abstract class SeasonDeadlineCatchupMixin {
   @Unique
   private static int tesles$previousLayers = -1;
   @Unique
   private static boolean tesles$previousHardEndpoint;

   @Inject(
      method = {"tick(Lnet/minecraft/server/MinecraftServer;Lfi/tesles/seasons/api/SeasonSnapshot;)V"},
      at = {@At("HEAD")},
      remap = false,
      require = 1
   )
   private static void tesles$queueDiscretePhysicalCheckpoints(MinecraftServer server, SeasonSnapshot snapshot, CallbackInfo ci) {
      if (snapshot != null) {
         int layers = ProportionalSeasonModel.baseSnowLayers(snapshot);
         boolean hard = isHardEndpoint(snapshot);
         if (tesles$previousLayers >= 0 && layers != tesles$previousLayers) {
            SeasonalWorldReconciler.queueAllLoadedUrgent();
         }

         if (hard && !tesles$previousHardEndpoint) {
            SeasonalWorldReconciler.queueAllLoadedUrgent();
         }

         tesles$previousLayers = layers;
         tesles$previousHardEndpoint = hard;
      }
   }

   @Inject(
      method = {"tick(Lnet/minecraft/server/MinecraftServer;Lfi/tesles/seasons/api/SeasonSnapshot;)V"},
      at = {@At("TAIL")},
      remap = false,
      require = 1
   )
   private static void tesles$finishExactEndpoints(MinecraftServer server, SeasonSnapshot snapshot, CallbackInfo ci) {
      EndpointChannelCanonicalizer.sweepLoadedEndpoints(snapshot, 4);
   }

   @Unique
   private static boolean isHardEndpoint(SeasonSnapshot s) {
      float leaf = clamp01(s.leafRetention());
      float snow = clamp01(s.snowCover());
      boolean leafEndpoint = leaf <= 0.001F || leaf >= 0.999F;
      boolean snowEndpoint = snow <= 0.005F || snow >= 0.995F;
      return leafEndpoint && snowEndpoint && !s.snowAccumulating() && !s.snowThawing();
   }

   @Unique
   private static float clamp01(float value) {
      return Math.max(0.0F, Math.min(1.0F, value));
   }
}
