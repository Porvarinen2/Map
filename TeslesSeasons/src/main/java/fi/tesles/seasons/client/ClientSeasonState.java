package fi.tesles.seasons.client;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.render.NearMeshRefreshQueue;
import fi.tesles.seasons.sector.SeasonDirector;
import fi.tesles.seasons.sector.SeasonFrame;
import net.minecraft.client.Minecraft;

public final class ClientSeasonState {
   private static final long DEFAULT_VISUAL_SEED = 7302026L;
   private static volatile SeasonSnapshot snapshot = SeasonSnapshot.summerDefault(7302026L);

   private ClientSeasonState() {
   }

   public static SeasonSnapshot get() {
      return snapshot;
   }

   /**
    * The current season as an absolute target frame. This is what render-side projectors
    * should read; the raw {@link SeasonSnapshot} is the wire format, not the contract.
    */
   public static SeasonFrame frame() {
      return SeasonDirector.currentFrame();
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
