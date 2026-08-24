package fi.tesles.seasons.api;

import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;

public record SeasonSnapshot(
   Season season,
   Season previousSeason,
   Season nextSeason,
   CalendarPhase phase,
   float phaseProgress,
   float seasonCycleValue,
   float autumnColor,
   float leafRetention,
   float flowerRetention,
   float mushroomRetention,
   float groundDormancy,
   float snowCover,
   float springFreshness,
   float treeGrowthFactor,
   float seedDropFactor,
   float fruitProductionFactor,
   boolean snowAccumulating,
   boolean snowThawing,
   int year,
   int month,
   int dayOfMonth,
   long visualSeed,
   int visualBucket
) {
   public static SeasonSnapshot summerDefault(long seed) {
      return new SeasonSnapshot(
         Season.SUMMER,
         Season.SPRING,
         Season.AUTUMN,
         CalendarPhase.STABLE,
         0.0F,
         1.5F,
         0.0F,
         1.0F,
         1.0F,
         0.0F,
         0.0F,
         0.0F,
         0.0F,
         1.0F,
         0.75F,
         1.0F,
         false,
         false,
         1970,
         1,
         1,
         seed,
         0
      );
   }
}
