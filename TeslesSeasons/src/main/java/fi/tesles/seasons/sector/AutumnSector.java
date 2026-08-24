package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;

public final class AutumnSector implements SeasonSector {
   @Override
   public SeasonFrame frame(SeasonSnapshot raw) {
      float p = clamp(raw.phaseProgress());
      CalendarPhase phase = raw.phase();
      float leaves;
      float flowers;
      float dormancy;
      float frost;
      float snowCoverage;
      float snowDepth;
      float mushrooms;
      if (phase == CalendarPhase.INCOMING) {
         leaves = 1.0F;
         flowers = 1.0F;
         dormancy = p;
         frost = 0.15F * p;
         snowCoverage = 0.0F;
         snowDepth = 0.0F;
         mushrooms = p;
      } else if (phase == CalendarPhase.STABLE) {
         leaves = 1.0F - p;
         flowers = 1.0F - p;
         dormancy = 1.0F;
         frost = 0.15F + 0.25F * p;
         snowCoverage = 0.0F;
         snowDepth = 0.0F;
         mushrooms = 1.0F;
      } else {
         leaves = 0.0F;
         flowers = 0.0F;
         dormancy = 1.0F;
         frost = 0.4F + 0.6F * p;
         snowCoverage = p;
         snowDepth = p <= 0.0F ? 0.0F : 0.125F;
         mushrooms = 1.0F - p;
      }

      return new SeasonFrame(
         raw.season(),
         phase,
         p,
         1.0F,
         leaves,
         flowers,
         1.0F,
         mushrooms,
         dormancy,
         frost,
         snowCoverage,
         snowDepth,
         0.0F,
         Math.max(0.0F, 0.35F * (1.0F - p)),
         0.9F,
         0.55F,
         phase == CalendarPhase.OUTGOING && p > 0.0F,
         false
      );
   }

   private static float clamp(float x) {
      return Math.max(0.0F, Math.min(1.0F, x));
   }
}
