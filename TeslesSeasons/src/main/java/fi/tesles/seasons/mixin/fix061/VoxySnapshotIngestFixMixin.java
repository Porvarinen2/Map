package fi.tesles.seasons.mixin.fix061;

import fi.tesles.seasons.fix061.VoxyNeutralSnapshot;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.common.world.service.VoxelIngestService"},
   remap = false
)
public abstract class VoxySnapshotIngestFixMixin {
   @Unique
   private static final ThreadLocal<LevelChunkSection[]> TESLES$SNAPSHOT = new ThreadLocal<>();

   @Inject(
      method = {"enqueueIngest(Lme/cortex/voxy/common/world/WorldEngine;Lnet/minecraft/world/level/chunk/LevelChunk;)Z"},
      at = {@At("HEAD")},
      remap = false,
      require = 1
   )
   private void tesles$beginSnapshot(CallbackInfoReturnable<Boolean> cir) {
      TESLES$SNAPSHOT.remove();
   }

   @Redirect(
      method = {"enqueueIngest(Lme/cortex/voxy/common/world/WorldEngine;Lnet/minecraft/world/level/chunk/LevelChunk;)Z"},
      at = @At(
         value = "INVOKE",
         target = "Lnet/minecraft/world/level/chunk/LevelChunk;getSections()[Lnet/minecraft/world/level/chunk/LevelChunkSection;"
      ),
      remap = false,
      require = 3
   )
   private LevelChunkSection[] tesles$neutralImmutableSections(LevelChunk chunk) {
      LevelChunkSection[] snapshot = TESLES$SNAPSHOT.get();
      if (snapshot == null) {
         snapshot = VoxyNeutralSnapshot.copyAndNeutralize(chunk);
         TESLES$SNAPSHOT.set(snapshot);
      }

      return snapshot;
   }

   @Inject(
      method = {"enqueueIngest(Lme/cortex/voxy/common/world/WorldEngine;Lnet/minecraft/world/level/chunk/LevelChunk;)Z"},
      at = {@At("RETURN")},
      remap = false,
      require = 1
   )
   private void tesles$endSnapshot(CallbackInfoReturnable<Boolean> cir) {
      TESLES$SNAPSHOT.remove();
   }
}
