package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;

/**
 * Winter: full snow footprint with accumulating depth, zero deciduous leaves and zero
 * winter-forbidden flora.
 *
 * <p>Winter Incoming is a seamless handoff: it inherits the complete 1/8 footprint that
 * Autumn Outgoing finished building and must never reset coverage to zero. Winter Stable
 * maps phase progress directly to normalised depth (progress 0.54 -> 4.32/8, realised as a
 * deterministic mix of 4/8 and 5/8 placements). Winter Outgoing melts footprint and depth
 * together.
 */
public final class WinterSector implements SeasonSector {
   /** The 1/8 footprint handed over by Autumn Outgoing. */
   private static final float HANDOFF_DEPTH = 0.125F;

   @Override
   public SeasonFrame frame(SeasonSnapshot raw) {
      float p = SeasonSector.clamp(raw.phaseProgress());
      CalendarPhase phase = raw.phase();

      float coverage;
      float depth;
      switch (phase) {
         case INCOMING -> {
            // Seamless continuation of the completed Autumn Outgoing footprint.
            coverage = 1.0F;
            depth = HANDOFF_DEPTH;
         }
         case STABLE -> {
            coverage = 1.0F;
            // max() keeps the Winter Incoming endpoint (1/8) continuous at p == 0 while
            // letting progress drive depth directly for the rest of the phase.
            depth = Math.max(HANDOFF_DEPTH, p);
         }
         default -> {
            // Canonical mapping: footprint and depth both retreat as 1 - progress. How an
            // individual column gets from its current depth to zero is SnowSystem's business -
            // see the melt feathering there, which keeps this aggregate while letting each column
            // come down a layer at a time.
            float remaining = 1.0F - p;
            coverage = remaining;
            depth = remaining;
         }
      }

      // Autumn Outgoing ends with a fully saturated autumn palette; Winter Incoming fades it
      // out rather than snapping to zero at midnight.
      float autumnColour = phase == CalendarPhase.INCOMING ? 1.0F - p : 0.0F;

      return SeasonFrame.builder(raw.season(), phase, p)
         .autumnColor(autumnColour)
         .leaves(0.0F)
         .flowers(0.0F)
         .plants(0.0F)
         .mushrooms(0.0F)
         .berries(0.0F)
         .dormancy(1.0F)
         .frost(1.0F)
         .snow(coverage, depth)
         .freshness(0.0F)
         .growth(0.0F)
         .seedDrop(0.0F)
         .fruit(0.0F)
         .accumulating(phase == CalendarPhase.INCOMING || phase == CalendarPhase.STABLE)
         .thawing(phase == CalendarPhase.OUTGOING)
         .build();
   }
}
