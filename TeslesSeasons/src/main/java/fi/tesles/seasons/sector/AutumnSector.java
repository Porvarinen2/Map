package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;

/**
 * Autumn: mushrooms rise then fall, deciduous leaves physically drop, and the first snow
 * footprint appears.
 *
 * <p>Snow in Autumn Outgoing is <em>coverage only</em>: every selected column carries
 * exactly one layer (1/8). Depth accumulation is Winter Stable's contract. Coverage runs
 * 0->100% so that Winter Incoming can take over a complete 1/8 footprint without ever
 * resetting it to zero.
 */
public final class AutumnSector implements SeasonSector {
   /** Autumn Outgoing places strictly one snow layer: 1/8 == 0.125 normalised depth. */
   private static final float FIRST_SNOW_DEPTH = 0.125F;

   @Override
   public SeasonFrame frame(SeasonSnapshot raw) {
      float p = SeasonSector.clamp(raw.phaseProgress());
      CalendarPhase phase = raw.phase();

      float leaves = switch (phase) {
         case INCOMING -> 1.0F;
         case STABLE -> 1.0F - p;
         case OUTGOING -> 0.0F;
      };

      // Mushrooms: 0->100 in Incoming, 100 in Stable, 100->0 in Outgoing.
      float mushrooms = switch (phase) {
         case INCOMING -> p;
         case STABLE -> 1.0F;
         case OUTGOING -> 1.0F - p;
      };

      // Flowers and berries converge downward through Stable and are gone by Outgoing.
      float flowers = switch (phase) {
         case INCOMING -> 1.0F;
         case STABLE -> 1.0F - p;
         case OUTGOING -> 0.0F;
      };

      // Ground plants survive longer than flowers, then fade out under the arriving snow so
      // that Winter Incoming can start from exactly 0 with no visible pop.
      float plants = switch (phase) {
         case INCOMING, STABLE -> 1.0F;
         case OUTGOING -> 1.0F - p;
      };

      float dormancy = phase == CalendarPhase.INCOMING ? p : 1.0F;

      float frost = switch (phase) {
         case INCOMING -> 0.15F * p;
         case STABLE -> 0.15F + 0.25F * p;
         case OUTGOING -> 0.40F + 0.60F * p;
      };

      float coverage = phase == CalendarPhase.OUTGOING ? p : 0.0F;
      float depth = phase == CalendarPhase.OUTGOING ? FIRST_SNOW_DEPTH : 0.0F;

      // Growth has already stopped by Autumn Stable; Incoming tapers it off continuously
      // from the Summer Outgoing endpoint of 1.0.
      float growth = phase == CalendarPhase.INCOMING ? 1.0F - p : 0.0F;
      float seedDrop = switch (phase) {
         case INCOMING, STABLE -> 1.0F;
         case OUTGOING -> 1.0F - p;
      };
      float fruit = phase == CalendarPhase.INCOMING ? 1.0F - p : 0.0F;

      return SeasonFrame.builder(raw.season(), phase, p)
         .autumnColor(1.0F)
         .leaves(leaves)
         .flowers(flowers)
         .plants(plants)
         .mushrooms(mushrooms)
         .berries(flowers)
         .dormancy(dormancy)
         .frost(frost)
         .snow(coverage, depth)
         .freshness(0.0F)
         .growth(growth)
         .seedDrop(seedDrop)
         .fruit(fruit)
         .accumulating(phase == CalendarPhase.OUTGOING && p > 0.0F)
         .build();
   }
}
