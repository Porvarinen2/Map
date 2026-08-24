package fi.tesles.seasons.api;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.calendar.Season;

public final class TeslesSeasonsApi {
   private TeslesSeasonsApi() {
   }

   public static SeasonSnapshot snapshot() {
      return SeasonEngine.current();
   }

   public static Season season() {
      return snapshot().season();
   }

   public static float transitionProgress() {
      return snapshot().phaseProgress();
   }
}
