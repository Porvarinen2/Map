package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;

/**
 * Summer: the canonical full-green world. Leaves and flora sit at 100%, snow and mushrooms
 * at 0. Summer Outgoing runs the autumn foliage colour transform 0->100% while physical
 * leaf retention deliberately stays at 100% (the drop is Autumn Stable's contract).
 */
public final class SummerSector implements SeasonSector {
   @Override
   public SeasonFrame frame(SeasonSnapshot raw) {
      float p = SeasonSector.clamp(raw.phaseProgress());
      CalendarPhase phase = raw.phase();

      float autumnColour = phase == CalendarPhase.OUTGOING ? p : 0.0F;
      float seedDrop = phase == CalendarPhase.OUTGOING ? p : 0.0F;

      return SeasonFrame.builder(raw.season(), phase, p)
         .autumnColor(autumnColour)
         .leaves(1.0F)
         .flowers(1.0F)
         .plants(1.0F)
         .mushrooms(0.0F)
         .berries(1.0F)
         .dormancy(0.0F)
         .frost(0.0F)
         .snow(0.0F, 0.0F)
         .freshness(0.0F)
         .growth(1.0F)
         .seedDrop(seedDrop)
         .fruit(1.0F)
         .build();
   }
}
