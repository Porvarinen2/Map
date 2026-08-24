package fi.tesles.seasons.sector;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;

/**
 * The single authoritative description of "what the world should look like right now".
 *
 * <p>Every field is an <em>absolute world target</em>, never a delta and never scheduler
 * progress. Downstream projectors (snow, leaves, flora, ground colour, Dynamic Trees,
 * client sync, Voxy) read this record and converge the world toward it. No subsystem is
 * allowed to invent, cache or reinterpret its own season history.
 *
 * <p>{@link #revision()} is the only non-target field. It is monotonic and exists purely so
 * schedulers can coalesce work: if revisions 53, 54 and 55 arrive before a chunk is
 * processed, the chunk is taken straight to 55. It is deliberately excluded from
 * {@link #sameTargets(SeasonFrame)} so that a revision bump alone never looks like a
 * target change.
 */
public record SeasonFrame(
   Season season,
   CalendarPhase phase,
   float progress,
   long revision,
   float autumnColor,
   float leafRetention,
   float flowerRetention,
   float plantRetention,
   float mushroomRetention,
   float berryRetention,
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
   public SeasonFrame {
      progress = clamp01(progress);
      autumnColor = clamp01(autumnColor);
      leafRetention = clamp01(leafRetention);
      flowerRetention = clamp01(flowerRetention);
      plantRetention = clamp01(plantRetention);
      mushroomRetention = clamp01(mushroomRetention);
      berryRetention = clamp01(berryRetention);
      groundDormancy = clamp01(groundDormancy);
      groundFrost = clamp01(groundFrost);
      snowCoverage = clamp01(snowCoverage);
      snowDepth = clamp01(snowDepth);
      springFreshness = clamp01(springFreshness);
      treeGrowthFactor = clamp01(treeGrowthFactor);
      seedDropFactor = clamp01(seedDropFactor);
      fruitProductionFactor = clamp01(fruitProductionFactor);
   }

   public static Builder builder(Season season, CalendarPhase phase, float progress) {
      return new Builder(season, phase, progress);
   }

   public SeasonFrame withRevision(long newRevision) {
      return new SeasonFrame(
         this.season, this.phase, this.progress, newRevision,
         this.autumnColor, this.leafRetention, this.flowerRetention, this.plantRetention,
         this.mushroomRetention, this.berryRetention, this.groundDormancy, this.groundFrost,
         this.snowCoverage, this.snowDepth, this.springFreshness,
         this.treeGrowthFactor, this.seedDropFactor, this.fruitProductionFactor,
         this.snowAccumulating, this.snowThawing
      );
   }

   /**
    * Target equality ignoring {@link #revision()}. Used to decide whether a new frame
    * actually asks the world for something different, so that Stable phases which change
    * no target do not trigger pointless world-wide rewrites.
    */
   public boolean sameTargets(SeasonFrame other) {
      return other != null
         && this.season == other.season
         && this.phase == other.phase
         && eq(this.progress, other.progress)
         && eq(this.autumnColor, other.autumnColor)
         && eq(this.leafRetention, other.leafRetention)
         && eq(this.flowerRetention, other.flowerRetention)
         && eq(this.plantRetention, other.plantRetention)
         && eq(this.mushroomRetention, other.mushroomRetention)
         && eq(this.berryRetention, other.berryRetention)
         && eq(this.groundDormancy, other.groundDormancy)
         && eq(this.groundFrost, other.groundFrost)
         && eq(this.snowCoverage, other.snowCoverage)
         && eq(this.snowDepth, other.snowDepth)
         && eq(this.springFreshness, other.springFreshness)
         && eq(this.treeGrowthFactor, other.treeGrowthFactor)
         && eq(this.seedDropFactor, other.seedDropFactor)
         && eq(this.fruitProductionFactor, other.fruitProductionFactor)
         && this.snowAccumulating == other.snowAccumulating
         && this.snowThawing == other.snowThawing;
   }

   /**
    * Coverage-weighted snow amount. Snow depth is only meaningful where coverage selects a
    * column, so this product is the channel that must stay continuous across the
    * Autumn Outgoing -> Winter Incoming and Winter Outgoing -> Spring Incoming boundaries.
    */
   public float effectiveSnow() {
      return this.snowCoverage * this.snowDepth;
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

   private static boolean eq(float a, float b) {
      return Math.abs(a - b) <= 1.0E-6F;
    }

   private static float clamp01(float value) {
      return Math.max(0.0F, Math.min(1.0F, value));
   }

   /** Keeps the 20-component canonical constructor from becoming an unreadable argument wall. */
   public static final class Builder {
      private final Season season;
      private final CalendarPhase phase;
      private final float progress;
      private float autumnColor;
      private float leafRetention;
      private float flowerRetention;
      private float plantRetention;
      private float mushroomRetention;
      private float berryRetention;
      private float groundDormancy;
      private float groundFrost;
      private float snowCoverage;
      private float snowDepth;
      private float springFreshness;
      private float treeGrowthFactor;
      private float seedDropFactor;
      private float fruitProductionFactor;
      private boolean snowAccumulating;
      private boolean snowThawing;

      private Builder(Season season, CalendarPhase phase, float progress) {
         this.season = season;
         this.phase = phase;
         this.progress = progress;
      }

      public Builder autumnColor(float v) { this.autumnColor = v; return this; }
      public Builder leaves(float v) { this.leafRetention = v; return this; }
      public Builder flowers(float v) { this.flowerRetention = v; return this; }
      public Builder plants(float v) { this.plantRetention = v; return this; }
      public Builder mushrooms(float v) { this.mushroomRetention = v; return this; }
      public Builder berries(float v) { this.berryRetention = v; return this; }
      public Builder dormancy(float v) { this.groundDormancy = v; return this; }
      public Builder frost(float v) { this.groundFrost = v; return this; }
      public Builder snow(float coverage, float depth) {
         this.snowCoverage = coverage;
         this.snowDepth = depth;
         return this;
      }
      public Builder freshness(float v) { this.springFreshness = v; return this; }
      public Builder growth(float v) { this.treeGrowthFactor = v; return this; }
      public Builder seedDrop(float v) { this.seedDropFactor = v; return this; }
      public Builder fruit(float v) { this.fruitProductionFactor = v; return this; }
      public Builder accumulating(boolean v) { this.snowAccumulating = v; return this; }
      public Builder thawing(boolean v) { this.snowThawing = v; return this; }

      public SeasonFrame build() {
         return new SeasonFrame(
            this.season, this.phase, this.progress, 0L,
            this.autumnColor, this.leafRetention, this.flowerRetention, this.plantRetention,
            this.mushroomRetention, this.berryRetention, this.groundDormancy, this.groundFrost,
            this.snowCoverage, this.snowDepth, this.springFreshness,
            this.treeGrowthFactor, this.seedDropFactor, this.fruitProductionFactor,
            this.snowAccumulating, this.snowThawing
         );
      }
   }
}
