package fi.tesles.seasons.mixin;

import fi.tesles.seasons.world.SeasonalWorldReconciler;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.network.PlayerChunkSender;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import net.minecraft.world.level.chunk.LevelChunk;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin({PlayerChunkSender.class})
public abstract class PlayerChunkSenderMixin {
   @Inject(
      method = {"sendChunk"},
      at = {@At("HEAD")}
   )
   private static void tesles$materializeSeasonBeforeChunkPacket(ServerGamePacketListenerImpl connection, ServerLevel level, LevelChunk chunk, CallbackInfo ci) {
      SeasonalWorldReconciler.reconcileBeforeSend(level, chunk);
   }
}
