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
    * Granularity at which a target counts as having changed.
    *
    * <p>This is the single most performance-critical constant in the mod. A revision bump
    * means "redo the world": the server re-queues every loaded chunk and the client
    * invalidates and rebuilds every Voxy LOD section. Comparing raw floats makes that happen
    * on <em>every clock refresh</em> - the calendar advances continuously, so any two samples
    * 30 seconds apart differ in the last few bits and look like a real change.
    *
    * <p>1/256 over a seven-day phase is one step roughly every forty minutes, which is far
    * below the threshold where a player notices snow or leaves advancing, and far above the
    * rate at which rebuilding the LOD set is affordable.
    */
   private static final float TARGET_QUANTUM = 1.0F / 256.0F;

   private static int quantize(float value) {
      return Math.round(value / TARGET_QUANTUM);
   }

   /**
    * Target equality ignoring {@link #revision()}.
    *
    * <p>{@code progress} is deliberately excluded: it is the clock <em>input</em>, not a
    * target. Every visual target is derived from it, so if all derived targets are unchanged
    * the world has nothing to do, however much raw progress has advanced.
    */
   public boolean sameTargets(SeasonFrame other) {
      return other != null
         && this.season == other.season
         && this.phase == other.phase
         && same(this.autumnColor, other.autumnColor)
         && same(this.leafRetention, other.leafRetention)
         && same(this.flowerRetention, other.flowerRetention)
         && same(this.plantRetention, other.plantRetention)
         && same(this.mushroomRetention, other.mushroomRetention)
         && same(this.berryRetention, other.berryRetention)
         && same(this.groundDormancy, other.groundDormancy)
         && same(this.groundFrost, other.groundFrost)
         && same(this.snowCoverage, other.snowCoverage)
         && same(this.snowDepth, other.snowDepth)
         && same(this.springFreshness, other.springFreshness)
         && same(this.treeGrowthFactor, other.treeGrowthFactor)
         && same(this.seedDropFactor, other.seedDropFactor)
         && same(this.fruitProductionFactor, other.fruitProductionFactor)
         && this.snowAccumulating == other.snowAccumulating
         && this.snowThawing == other.snowThawing;
   }

   /**
    * Identity of everything that changes Voxy LOD <em>geometry</em>.
    *
    * <p>The LOD mesh projector only ever adds or removes snow, so snow coverage and depth are
    * the only channels that can make a rebuilt section differ from a cached one. Colour
    * channels reach Voxy as shader uniforms, which are uploaded per bind and need no remesh.
    *
    * <p>Keying LOD invalidation on this instead of on the full frame revision means that in
    * Spring, Summer and most of Autumn - whenever snow coverage is zero - the value never
    * changes and not a single section is ever rebuilt for seasonal reasons.
    */
   public long geometryKey() {
      if (this.snowCoverage <= 0.0F) {
         // No snow anywhere: every snow-free frame is the same geometry, regardless of season.
         return 0L;
      }
      return ((long) quantize(this.snowCoverage) << 32) | (quantize(this.snowDepth) & 0xFFFFFFFFL);
   }

   private static boolean same(float a, float b) {
      return quantize(a) == quantize(b);
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
