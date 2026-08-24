package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;

/**
 * Spring: winter residue is already gone, physical leaves come back, and the placeholder
 * short grass left by Winter Outgoing is progressively replaced by canonical flora.
 *
 * <p>Spring-wide flora restoration is one continuous 0..1 channel spanning all three phases
 * (Incoming ~0-33%, Stable ~33-67%, Outgoing ~67-100%), so Summer starts at exactly 100%.
 */
public final class SpringSector implements SeasonSector {
   @Override
   public SeasonFrame frame(SeasonSnapshot raw) {
      float p = SeasonSector.clamp(raw.phaseProgress());
      CalendarPhase phase = raw.phase();

      // One continuous Spring-wide flora channel; each phase covers one third of it.
      float flora = switch (phase) {
         case INCOMING -> p / 3.0F;
         case STABLE -> (1.0F + p) / 3.0F;
         case OUTGOING -> (2.0F + p) / 3.0F;
      };

      // Deciduous leaves return deterministically across Spring Stable, then stay full.
      float leaves = switch (phase) {
         case INCOMING -> 0.0F;
         case STABLE -> p;
         case OUTGOING -> 1.0F;
      };

      // Winter leaves the ground fully frozen/dormant; Spring Incoming thaws it smoothly.
      float frost = phase == CalendarPhase.INCOMING ? 1.0F - p : 0.0F;

      float freshness = switch (phase) {
         case INCOMING -> p;
         case STABLE -> 1.0F;
         case OUTGOING -> 1.0F - p;
      };

      return SeasonFrame.builder(raw.season(), phase, p)
         .autumnColor(0.0F)
         .leaves(leaves)
         .flowers(flora)
         .plants(flora)
         .mushrooms(0.0F)
         .berries(flora)
         .dormancy(frost)
         .frost(frost)
         .snow(0.0F, 0.0F)
         .freshness(freshness)
         // Growth follows the same continuous flora ramp: 0 at the Winter handoff, 1 into Summer.
         .growth(flora)
         .seedDrop(0.0F)
         .fruit(flora)
         .build();
   }
}
