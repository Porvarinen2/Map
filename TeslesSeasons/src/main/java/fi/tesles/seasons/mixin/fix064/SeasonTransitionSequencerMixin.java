package fi.tesles.seasons.mixin.fix064;

import fi.tesles.seasons.TeslesSeasonsConfig;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.fix069.ProportionalSeasonModel;
import java.time.ZonedDateTime;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Coerce;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(
   targets = {"fi.tesles.seasons.calendar.RealCalendarSeasonClock"},
   remap = false
)
public abstract class SeasonTransitionSequencerMixin {
   @Inject(
      method = {"snapshot"},
      at = {@At("RETURN")},
      cancellable = true,
      remap = false,
      require = 1
   )
   private static void tesles$literalPhaseTargets(
      Season season,
      Season previousSeason,
      Season nextSeason,
      CalendarPhase phase,
      float phaseProgress,
      float seasonCycleValue,
      @Coerce Object channels,
      ZonedDateTime now,
      TeslesSeasonsConfig config,
      int bucketOffset,
      boolean debug,
      CallbackInfoReturnable<SeasonSnapshot> cir
   ) {
      SeasonSnapshot original = (SeasonSnapshot)cir.getReturnValue();
      SeasonSnapshot proportional = ProportionalSeasonModel.apply(original);
      if (proportional != null) {
         cir.setReturnValue(proportional);
      }
   }
}
