package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;

public record SeasonFrame(
   Season season,
   CalendarPhase phase,
   float progress,
   float autumnColor,
   float leafRetention,
   float flowerRetention,
   float plantRetention,
   float mushroomRetention,
   float groundDormancy,
   float groundFrost,
   float snowCoverage,
   float snowDepth,
   float springFreshness,
   float treeGrowthFactor,
   float seedDropFactor,
   float fruitProductionFactor,
   boolean snowAccumulating,
   boolean snowThawing
) {
   public SeasonFrame(
      Season season,
      CalendarPhase phase,
      float progress,
      float autumnColor,
      float leafRetention,
      float flowerRetention,
      float plantRetention,
      float mushroomRetention,
      float groundDormancy,
      float groundFrost,
      float snowCoverage,
      float snowDepth,
      float springFreshness,
      float treeGrowthFactor,
      float seedDropFactor,
      float fruitProductionFactor,
      boolean snowAccumulating,
      boolean snowThawing
   ) {
      progress = clamp01(progress);
      autumnColor = clamp01(autumnColor);
      leafRetention = clamp01(leafRetention);
      flowerRetention = clamp01(flowerRetention);
      plantRetention = clamp01(plantRetention);
      mushroomRetention = clamp01(mushroomRetention);
      groundDormancy = clamp01(groundDormancy);
      groundFrost = clamp01(groundFrost);
      snowCoverage = clamp01(snowCoverage);
      snowDepth = clamp01(snowDepth);
      springFreshness = clamp01(springFreshness);
      treeGrowthFactor = clamp01(treeGrowthFactor);
      seedDropFactor = clamp01(seedDropFactor);
      fruitProductionFactor = clamp01(fruitProductionFactor);
      this.season = season;
      this.phase = phase;
      this.progress = progress;
      this.autumnColor = autumnColor;
      this.leafRetention = leafRetention;
      this.flowerRetention = flowerRetention;
      this.plantRetention = plantRetention;
      this.mushroomRetention = mushroomRetention;
      this.groundDormancy = groundDormancy;
      this.groundFrost = groundFrost;
      this.snowCoverage = snowCoverage;
      this.snowDepth = snowDepth;
      this.springFreshness = springFreshness;
      this.treeGrowthFactor = treeGrowthFactor;
      this.seedDropFactor = seedDropFactor;
      this.fruitProductionFactor = fruitProductionFactor;
      this.snowAccumulating = snowAccumulating;
      this.snowThawing = snowThawing;
   }

   public SeasonSnapshot toLegacy(SeasonSnapshot raw) {
      int baseBucket = this.season.ordinal() * 300 + this.phase.ordinal() * 100 + Math.round(this.progress * 100.0F);
      int bucket = raw.visualBucket() >= 1000000 ? 1000000 + baseBucket : baseBucket;
      return new SeasonSnapshot(
         this.season,
         raw.previousSeason(),
         raw.nextSeason(),
         this.phase,
         this.progress,
         raw.seasonCycleValue(),
         this.autumnColor,
         this.leafRetention,
         this.flowerRetention,
         this.mushroomRetention,
         this.groundDormancy,
         this.snowCoverage,
         this.springFreshness,
         this.treeGrowthFactor,
         this.seedDropFactor,
         this.fruitProductionFactor,
         this.snowAccumulating,
         this.snowThawing,
         raw.year(),
         raw.month(),
         raw.dayOfMonth(),
         raw.visualSeed(),
         bucket
      );
   }

   private static float clamp01(float value) {
      return Math.max(0.0F, Math.min(1.0F, value));
   }
}
