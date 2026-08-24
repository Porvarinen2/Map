package fi.tesles.seasons.mixin.fix064;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.api.SeasonSnapshot;
import java.util.ArrayDeque;
import java.util.Iterator;
import java.util.Set;
import java.util.concurrent.ThreadLocalRandom;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.chunk.LevelChunk;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   targets = {"fi.tesles.seasons.world.SeasonalWorldReconciler"},
   remap = false
)
public abstract class RandomWorldReconcileSchedulerMixin {
   @Inject(
      method = {"pollQueue(Ljava/util/ArrayDeque;Ljava/util/Set;)Ljava/lang/Long;"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$randomUrgentFairWork(ArrayDeque<Long> queue, Set<Long> queued, CallbackInfoReturnable<Long> cir) {
      int size = queue.size();
      if (size == 0) {
         cir.setReturnValue(null);
      } else {
         ThreadLocalRandom rng = ThreadLocalRandom.current();
         int window = Math.min(size, 32);
         int bound = size > window && rng.nextInt(8) == 0 ? size : window;
         int target = bound == 1 ? 0 : rng.nextInt(bound);
         Iterator<Long> iterator = queue.iterator();
         Long selected = null;

         for (int i = 0; iterator.hasNext(); i++) {
            Long value = iterator.next();
            if (i == target) {
               selected = value;
               iterator.remove();
               break;
            }
         }

         if (selected != null) {
            queued.remove(selected);
         }

         cir.setReturnValue(selected);
      }
   }

   @Inject(
      method = {"reconcileBeforeSend(Lnet/minecraft/server/level/ServerLevel;Lnet/minecraft/world/level/chunk/LevelChunk;)V"},
      at = {@At("HEAD")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$onlyFullSyncAtCompletedEndpoint(ServerLevel level, LevelChunk chunk, CallbackInfo ci) {
      SeasonSnapshot snapshot = SeasonEngine.current();
      if (snapshot == null || !tesles$isHardDeadline(snapshot)) {
         ci.cancel();
      }
   }

   @Unique
   private static boolean tesles$isHardDeadline(SeasonSnapshot s) {
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
