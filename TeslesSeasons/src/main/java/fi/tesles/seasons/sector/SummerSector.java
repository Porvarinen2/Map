package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;

public final class SummerSector implements SeasonSector {
   @Override
   public SeasonFrame frame(SeasonSnapshot raw) {
      float p = clamp(raw.phaseProgress());
      CalendarPhase phase = raw.phase();
      float flowers = 1.0F;
      float fruit = phase == CalendarPhase.INCOMING ? p : 1.0F;
      float autumn = phase == CalendarPhase.OUTGOING ? p : 0.0F;
      return new SeasonFrame(raw.season(), phase, p, autumn, 1.0F, flowers, 1.0F, 0.0F, 0.0F, 0.0F, 0.0F, 0.0F, 0.0F, 1.0F, 0.85F, fruit, false, false);
   }

   private static float clamp(float x) {
      return Math.max(0.0F, Math.min(1.0F, x));
   }
}
