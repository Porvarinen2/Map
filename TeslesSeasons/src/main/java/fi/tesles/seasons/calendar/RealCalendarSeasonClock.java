package fi.tesles.seasons.calendar;

import fi.tesles.seasons.TeslesSeasonsConfig;
import fi.tesles.seasons.api.SeasonSnapshot;
import java.time.Instant;
import java.time.YearMonth;
import java.time.ZonedDateTime;

public final class RealCalendarSeasonClock {
   private static final int DEBUG_BUCKET_OFFSET = 1000000;

   private RealCalendarSeasonClock() {
   }

   public static SeasonSnapshot calculate(long nowMillis, TeslesSeasonsConfig config) {
      ZonedDateTime now = Instant.ofEpochMilli(nowMillis).atZone(config.zoneId());
      YearMonth ym = YearMonth.from(now);
      int length = ym.lengthOfMonth();
      int incoming = Math.max(1, Math.min(config.incomingTransitionDays, Math.max(1, length - 2)));
      int outgoing = Math.max(1, Math.min(config.outgoingTransitionDays, Math.max(1, length - incoming - 1)));
      int stableDays = Math.max(1, length - incoming - outgoing);
      double day = now.getDayOfMonth() - 1 + dayFraction(now);
      Season current = config.seasonForMonth(now.getMonth());
      Season previous = config.seasonForMonth(now.minusMonths(1L).getMonth());
      Season next = config.seasonForMonth(now.plusMonths(1L).getMonth());
      CalendarPhase phase;
      float progress;
      if (day < incoming) {
         phase = CalendarPhase.INCOMING;
         progress = clamp01((float)(day / incoming));
      } else if (day < incoming + stableDays) {
         phase = CalendarPhase.STABLE;
         progress = clamp01((float)((day - incoming) / stableDays));
      } else {
         phase = CalendarPhase.OUTGOING;
         progress = clamp01((float)((day - incoming - stableDays) / outgoing));
      }

      return snapshot(current, previous, next, phase, progress, now, config, false);
   }

   public static SeasonSnapshot calculateSummerStableBaseline(long nowMillis, TeslesSeasonsConfig config) {
      ZonedDateTime now = Instant.ofEpochMilli(nowMillis).atZone(config.zoneId());
      return snapshot(Season.SUMMER, Season.SPRING, Season.AUTUMN, CalendarPhase.STABLE, 0.5F, now, config, false);
   }

   public static SeasonSnapshot calculateDebugDate(long epochMillis, TeslesSeasonsConfig config) {
      SeasonSnapshot s = calculate(epochMillis, config);
      return withBucket(s, 1000000 + normalBucket(s.season(), s.phase(), s.phaseProgress()));
   }

   public static SeasonSnapshot calculateDebugStable(Season season, long nowMillis, TeslesSeasonsConfig config) {
      return calculateDebugPhase(season, CalendarPhase.STABLE, 1.0F, nowMillis, config);
   }

   public static SeasonSnapshot calculateDebugPhase(Season season, CalendarPhase phase, float progress, long nowMillis, TeslesSeasonsConfig config) {
      ZonedDateTime now = Instant.ofEpochMilli(nowMillis).atZone(config.zoneId());
      return snapshot(season, previousCanonical(season), nextCanonical(season), phase, clamp01(progress), now, config, true);
   }

   public static SeasonSnapshot calculateDebugYearLoop(float loopProgress, long nowMillis, TeslesSeasonsConfig config) {
      float p = Math.max(0.0F, Math.min(0.999999F, loopProgress));
      float rotated = p + 0.375F;
      if (rotated >= 1.0F) {
         rotated--;
      }

      float scaled = rotated * 12.0F;
      int segment = Math.min(11, (int)Math.floor(scaled));
      float phaseProgress = clamp01(scaled - segment);
      int seasonIndex = segment / 3;
      int phaseIndex = segment % 3;
      Season season = Season.values()[seasonIndex];
      CalendarPhase phase = CalendarPhase.values()[phaseIndex];
      return calculateDebugPhase(season, phase, phaseProgress, nowMillis, config);
   }

   public static SeasonSnapshot calculateDebugTransition(Season from, Season to, float transitionProgress, long nowMillis, TeslesSeasonsConfig config) {
      float p = clamp01(transitionProgress);
      return p < 0.5F
         ? calculateDebugPhase(from, CalendarPhase.OUTGOING, p * 2.0F, nowMillis, config)
         : calculateDebugPhase(to, CalendarPhase.INCOMING, (p - 0.5F) * 2.0F, nowMillis, config);
   }

   private static SeasonSnapshot snapshot(
      Season season, Season previous, Season next, CalendarPhase phase, float progress, ZonedDateTime now, TeslesSeasonsConfig config, boolean debug
   ) {
      float cycle = wrap4(season.ordinal() + (phase.ordinal() + progress) / 3.0F);
      int bucket = normalBucket(season, phase, progress) + (debug ? 1000000 : 0);
      return new SeasonSnapshot(
         season,
         previous,
         next,
         phase,
         progress,
         cycle,
         0.0F,
         1.0F,
         1.0F,
         1.0F,
         0.0F,
         0.0F,
         0.0F,
         1.0F,
         1.0F,
         1.0F,
         false,
         false,
         now.getYear(),
         now.getMonthValue(),
         now.getDayOfMonth(),
         config.visualSeed,
         bucket
      );
   }

   private static SeasonSnapshot withBucket(SeasonSnapshot s, int bucket) {
      return new SeasonSnapshot(
         s.season(),
         s.previousSeason(),
         s.nextSeason(),
         s.phase(),
         s.phaseProgress(),
         s.seasonCycleValue(),
         s.autumnColor(),
         s.leafRetention(),
         s.flowerRetention(),
         s.mushroomRetention(),
         s.groundDormancy(),
         s.snowCover(),
         s.springFreshness(),
         s.treeGrowthFactor(),
         s.seedDropFactor(),
         s.fruitProductionFactor(),
         s.snowAccumulating(),
         s.snowThawing(),
         s.year(),
         s.month(),
         s.dayOfMonth(),
         s.visualSeed(),
         bucket
      );
   }

   private static Season previousCanonical(Season season) {
      Season[] values = Season.values();
      return values[(season.ordinal() + values.length - 1) % values.length];
   }

   private static Season nextCanonical(Season season) {
      Season[] values = Season.values();
      return values[(season.ordinal() + 1) % values.length];
   }

   private static double dayFraction(ZonedDateTime now) {
      return (now.getHour() * 3600.0 + now.getMinute() * 60.0 + now.getSecond() + now.getNano() / 1.0E9) / 86400.0;
   }

   private static int normalBucket(Season season, CalendarPhase phase, float progress) {
      return season.ordinal() * 300 + phase.ordinal() * 100 + Math.round(clamp01(progress) * 100.0F);
   }

   private static float wrap4(float value) {
      float v = value % 4.0F;
      return v < 0.0F ? v + 4.0F : v;
   }

   private static float clamp01(float value) {
      return Math.max(0.0F, Math.min(1.0F, value));
   }
}
