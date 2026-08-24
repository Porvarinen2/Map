package fi.tesles.seasons.network;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;

public record SeasonWireState(
   String season,
   String previousSeason,
   String nextSeason,
   String phase,
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
   public static SeasonWireState from(SeasonSnapshot snapshot) {
      return new SeasonWireState(
         snapshot.season().name(),
         snapshot.previousSeason().name(),
         snapshot.nextSeason().name(),
         snapshot.phase().name(),
         snapshot.phaseProgress(),
         snapshot.seasonCycleValue(),
         snapshot.autumnColor(),
         snapshot.leafRetention(),
         snapshot.flowerRetention(),
         snapshot.mushroomRetention(),
         snapshot.groundDormancy(),
         snapshot.snowCover(),
         snapshot.springFreshness(),
         snapshot.treeGrowthFactor(),
         snapshot.seedDropFactor(),
         snapshot.fruitProductionFactor(),
         snapshot.snowAccumulating(),
         snapshot.snowThawing(),
         snapshot.year(),
         snapshot.month(),
         snapshot.dayOfMonth(),
         snapshot.visualSeed(),
         snapshot.visualBucket()
      );
   }

   public SeasonSnapshot toSnapshot() {
      return new SeasonSnapshot(
         Season.parse(this.season, Season.SUMMER),
         Season.parse(this.previousSeason, Season.SPRING),
         Season.parse(this.nextSeason, Season.AUTUMN),
         parsePhase(this.phase),
         this.phaseProgress,
         this.seasonCycleValue,
         this.autumnColor,
         this.leafRetention,
         this.flowerRetention,
         this.mushroomRetention,
         this.groundDormancy,
         this.snowCover,
         this.springFreshness,
         this.treeGrowthFactor,
         this.seedDropFactor,
         this.fruitProductionFactor,
         this.snowAccumulating,
         this.snowThawing,
         this.year,
         this.month,
         this.dayOfMonth,
         this.visualSeed,
         this.visualBucket
      );
   }

   private static CalendarPhase parsePhase(String value) {
      if (value == null) {
         return CalendarPhase.STABLE;
      } else {
         try {
            return CalendarPhase.valueOf(value);
         } catch (IllegalArgumentException var2) {
            return CalendarPhase.STABLE;
         }
      }
   }
}
