package fi.tesles.seasons;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.sector.SeasonDirector;
import fi.tesles.seasons.sector.SeasonFrame;

public final class SeasonEngine {
   private static volatile SeasonSnapshot current = SeasonSnapshot.summerDefault(7302026L);

   private SeasonEngine() {
   }

   public static SeasonSnapshot current() {
      return current;
   }

   public static SeasonFrame frame() {
      return SeasonDirector.currentFrame();
   }

   public static SeasonSnapshot refresh(long nowMillis) {
      current = SeasonDirector.refresh(nowMillis);
      return current;
   }

   public static void acceptRemote(SeasonSnapshot snapshot) {
      if (snapshot != null) {
         current = snapshot;
         SeasonDirector.acceptRemote(snapshot);
      }
   }
}
