package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;

public final class WinterSector implements SeasonSector {
   @Override
   public SeasonFrame frame(SeasonSnapshot raw) {
      float p = clamp(raw.phaseProgress());
      CalendarPhase phase = raw.phase();
      float depth;
      float coverage;
      float plants;
      if (phase == CalendarPhase.INCOMING) {
         coverage = 1.0F;
         depth = 0.125F;
         plants = 0.0F;
      } else if (phase == CalendarPhase.STABLE) {
         coverage = 1.0F;
         depth = Math.max(0.125F, p);
         plants = 0.0F;
      } else {
         depth = 1.0F - p;
         coverage = 1.0F - p;
         plants = 0.0F;
      }

      return new SeasonFrame(
         raw.season(),
         phase,
         p,
         0.0F,
         0.0F,
         0.0F,
         plants,
         0.0F,
         1.0F,
         1.0F,
         coverage,
         depth,
         0.0F,
         0.0F,
         0.0F,
         0.0F,
         phase == CalendarPhase.INCOMING,
         phase == CalendarPhase.OUTGOING
      );
   }

   private static float clamp(float x) {
      return Math.max(0.0F, Math.min(1.0F, x));
   }
}
