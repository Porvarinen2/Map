package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;

public final class SpringSector implements SeasonSector {
   @Override
   public SeasonFrame frame(SeasonSnapshot raw) {
      float p = clamp(raw.phaseProgress());
      CalendarPhase phase = raw.phase();

      float floraProgress = switch (phase) {
         case INCOMING -> p / 3.0F;
         case STABLE -> (1.0F + p) / 3.0F;
         case OUTGOING -> (2.0F + p) / 3.0F;
      };
      float leaves;
      float frost;
      float fresh;
      if (phase == CalendarPhase.INCOMING) {
         leaves = 0.0F;
         frost = 1.0F - p;
         fresh = p;
      } else if (phase == CalendarPhase.STABLE) {
         leaves = p;
         frost = 0.0F;
         fresh = 1.0F;
      } else {
         leaves = 1.0F;
         frost = 0.0F;
         fresh = 1.0F - p;
      }

      return new SeasonFrame(
         raw.season(),
         phase,
         p,
         0.0F,
         leaves,
         floraProgress,
         floraProgress,
         0.0F,
         frost,
         frost,
         0.0F,
         0.0F,
         fresh,
         0.45F + 0.55F * floraProgress,
         0.7F,
         0.55F + 0.3F * floraProgress,
         false,
         false
      );
   }

   private static float clamp(float x) {
      return Math.max(0.0F, Math.min(1.0F, x));
   }
}
