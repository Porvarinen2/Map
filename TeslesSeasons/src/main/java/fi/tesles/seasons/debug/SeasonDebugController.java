package fi.tesles.seasons.debug;

import fi.tesles.seasons.TeslesSeasonsConfig;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.RealCalendarSeasonClock;
import fi.tesles.seasons.calendar.Season;
import java.time.LocalDate;
import java.time.LocalTime;

public final class SeasonDebugController {
   private static volatile SeasonDebugController.OverrideState state = SeasonDebugController.OverrideState.none();

   private SeasonDebugController() {
   }

   public static boolean isActive() {
      return state.mode != SeasonDebugController.Mode.NONE;
   }

   public static boolean hasAnimatedOverride() {
      SeasonDebugController.Mode mode = state.mode;
      return mode == SeasonDebugController.Mode.TRANSITION || mode == SeasonDebugController.Mode.YEAR_LOOP || mode == SeasonDebugController.Mode.YEAR_ONCE;
   }

   public static boolean hasAnimatedTransition() {
      return hasAnimatedOverride();
   }

   public static boolean transitionComplete(long nowMillis) {
      SeasonDebugController.OverrideState current = state;
      return (current.mode == SeasonDebugController.Mode.TRANSITION || current.mode == SeasonDebugController.Mode.YEAR_ONCE) && nowMillis >= current.endMillis;
   }

   public static void finishTransition() {
      SeasonDebugController.OverrideState current = state;
      if (current.mode == SeasonDebugController.Mode.TRANSITION) {
         state = SeasonDebugController.OverrideState.fixedSeason(current.toSeason);
      } else if (current.mode == SeasonDebugController.Mode.YEAR_ONCE) {
         state = SeasonDebugController.OverrideState.none();
      }
   }

   public static void clear() {
      state = SeasonDebugController.OverrideState.none();
   }

   public static void forceSeason(Season season) {
      state = SeasonDebugController.OverrideState.fixedSeason(season);
   }

   public static void forceDate(LocalDate date, TeslesSeasonsConfig config) {
      long epochMillis = date.atTime(LocalTime.NOON).atZone(config.zoneId()).toInstant().toEpochMilli();
      state = SeasonDebugController.OverrideState.fixedDate(epochMillis, date);
   }

   public static void forcePhase(Season season, CalendarPhase phase, float progress) {
      state = SeasonDebugController.OverrideState.fixedPhase(season, phase, clamp01(progress));
   }

   public static void startTransition(Season from, Season to, int seconds, long nowMillis) {
      long durationMillis = Math.max(1L, (long)seconds) * 1000L;
      state = SeasonDebugController.OverrideState.transition(from, to, nowMillis, nowMillis + durationMillis);
   }

   public static void startYearLoop(int seconds, long nowMillis) {
      long durationMillis = Math.max(1L, (long)seconds) * 1000L;
      state = SeasonDebugController.OverrideState.yearLoop(nowMillis, durationMillis);
   }

   public static void startDiagnosticYear(int seconds, long nowMillis) {
      long durationMillis = Math.max(1L, (long)seconds) * 1000L;
      state = SeasonDebugController.OverrideState.yearOnce(nowMillis, durationMillis, nowMillis + durationMillis + 5000L);
   }

   public static SeasonSnapshot calculate(long nowMillis, TeslesSeasonsConfig config) {
      SeasonDebugController.OverrideState current = state;

      return switch (current.mode) {
         case NONE -> null;
         case FIXED_DATE -> RealCalendarSeasonClock.calculateDebugDate(current.fixedDateEpochMillis, config);
         case FIXED_SEASON -> RealCalendarSeasonClock.calculateDebugStable(current.toSeason, nowMillis, config);
         case FIXED_PHASE -> RealCalendarSeasonClock.calculateDebugPhase(current.toSeason, current.phase, current.phaseProgress, nowMillis, config);
         case TRANSITION -> {
            long duration = Math.max(1L, current.endMillis - current.startMillis);
            float progress = clamp01((float)((double)(nowMillis - current.startMillis) / duration));
            yield RealCalendarSeasonClock.calculateDebugTransition(current.fromSeason, current.toSeason, progress, nowMillis, config);
         }
         case YEAR_LOOP -> {
            long duration = Math.max(1L, current.loopDurationMillis);
            long elapsed = Math.floorMod(nowMillis - current.startMillis, duration);
            float progress = (float)((double)elapsed / duration);
            yield RealCalendarSeasonClock.calculateDebugYearLoop(progress, nowMillis, config);
         }
         case YEAR_ONCE -> {
            long duration = Math.max(1L, current.loopDurationMillis);
            long elapsed = Math.max(0L, Math.min(duration, nowMillis - current.startMillis));
            float progress = Math.min(0.9999F, (float)((double)elapsed / duration));
            yield RealCalendarSeasonClock.calculateDebugYearLoop(progress, nowMillis, config);
         }
      };
   }

   public static String description(long nowMillis, TeslesSeasonsConfig config) {
      SeasonDebugController.OverrideState current = state;

      return switch (current.mode) {
         case NONE -> "OFF (real calendar)";
         case FIXED_DATE -> "DATE " + current.fixedDate;
         case FIXED_SEASON -> "SEASON " + current.toSeason.name();
         case FIXED_PHASE -> "PHASE " + current.toSeason.name() + " " + current.phase.name() + " " + Math.round(current.phaseProgress * 100.0F) + "%";
         case TRANSITION -> {
            long duration = Math.max(1L, current.endMillis - current.startMillis);
            float progress = clamp01((float)((double)(nowMillis - current.startMillis) / duration));
            int remainingSeconds = Math.max(0, (int)Math.ceil((current.endMillis - nowMillis) / 1000.0));
            yield "TRANSITION "
               + current.fromSeason.name()
               + " -> "
               + current.toSeason.name()
               + " "
               + Math.round(progress * 100.0F)
               + "% ("
               + remainingSeconds
               + "s left)";
         }
         case YEAR_LOOP -> {
            long duration = Math.max(1L, current.loopDurationMillis);
            long elapsed = Math.floorMod(nowMillis - current.startMillis, duration);
            float progress = (float)((double)elapsed / duration);
            yield "YEAR LOOP " + Math.round(progress * 100.0F) + "% (" + Math.max(1L, duration / 1000L) + "s/year)";
         }
         case YEAR_ONCE -> {
            long duration = Math.max(1L, current.loopDurationMillis);
            long elapsed = Math.max(0L, Math.min(duration, nowMillis - current.startMillis));
            float progress = Math.min(1.0F, (float)((double)elapsed / duration));
            yield "DIAGNOSTIC YEAR " + Math.round(progress * 100.0F) + "% (" + Math.max(1L, duration / 1000L) + "s)";
         }
      };
   }

   private static float clamp01(float value) {
      return Math.max(0.0F, Math.min(1.0F, value));
   }

   private static enum Mode {
      NONE,
      FIXED_DATE,
      FIXED_SEASON,
      FIXED_PHASE,
      TRANSITION,
      YEAR_LOOP,
      YEAR_ONCE;
   }

   private record OverrideState(
      SeasonDebugController.Mode mode,
      long fixedDateEpochMillis,
      LocalDate fixedDate,
      Season fromSeason,
      Season toSeason,
      CalendarPhase phase,
      float phaseProgress,
      long startMillis,
      long endMillis,
      long loopDurationMillis
   ) {
      static SeasonDebugController.OverrideState none() {
         return new SeasonDebugController.OverrideState(SeasonDebugController.Mode.NONE, 0L, null, null, null, null, 0.0F, 0L, 0L, 0L);
      }

      static SeasonDebugController.OverrideState fixedDate(long epochMillis, LocalDate date) {
         return new SeasonDebugController.OverrideState(SeasonDebugController.Mode.FIXED_DATE, epochMillis, date, null, null, null, 0.0F, 0L, 0L, 0L);
      }

      static SeasonDebugController.OverrideState fixedSeason(Season season) {
         return new SeasonDebugController.OverrideState(SeasonDebugController.Mode.FIXED_SEASON, 0L, null, null, season, CalendarPhase.STABLE, 1.0F, 0L, 0L, 0L);
      }

      static SeasonDebugController.OverrideState fixedPhase(Season season, CalendarPhase phase, float progress) {
         return new SeasonDebugController.OverrideState(SeasonDebugController.Mode.FIXED_PHASE, 0L, null, null, season, phase, progress, 0L, 0L, 0L);
      }

      static SeasonDebugController.OverrideState transition(Season from, Season to, long startMillis, long endMillis) {
         return new SeasonDebugController.OverrideState(SeasonDebugController.Mode.TRANSITION, 0L, null, from, to, null, 0.0F, startMillis, endMillis, 0L);
      }

      static SeasonDebugController.OverrideState yearLoop(long startMillis, long durationMillis) {
         return new SeasonDebugController.OverrideState(SeasonDebugController.Mode.YEAR_LOOP, 0L, null, null, null, null, 0.0F, startMillis, 0L, durationMillis);
      }

      static SeasonDebugController.OverrideState yearOnce(long startMillis, long durationMillis, long endMillis) {
         return new SeasonDebugController.OverrideState(
            SeasonDebugController.Mode.YEAR_ONCE, 0L, null, null, null, null, 0.0F, startMillis, endMillis, durationMillis
         );
      }
   }
}
