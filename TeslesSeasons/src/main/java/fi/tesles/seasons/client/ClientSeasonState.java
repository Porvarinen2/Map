package fi.tesles.seasons.client;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.render.NearMeshRefreshQueue;
import net.minecraft.client.Minecraft;

public final class ClientSeasonState {
   private static final long DEFAULT_VISUAL_SEED = 7302026L;
   private static volatile SeasonSnapshot snapshot = SeasonSnapshot.summerDefault(7302026L);

   private ClientSeasonState() {
   }

   public static SeasonSnapshot get() {
      return snapshot;
   }

   public static void accept(SeasonSnapshot next) {
      SeasonSnapshot previous = snapshot;
      snapshot = next;
      SeasonEngine.acceptRemote(next);
      if (previous.visualBucket() != next.visualBucket()) {
         Minecraft client = Minecraft.getInstance();
         if (client.level != null && client.player != null) {
            NearMeshRefreshQueue.queueAroundPlayer(client);
         }
      }
   }

   public static void reset() {
      snapshot = SeasonSnapshot.summerDefault(7302026L);
      SeasonEngine.refresh(System.currentTimeMillis());
      NearMeshRefreshQueue.clear();
   }
}
