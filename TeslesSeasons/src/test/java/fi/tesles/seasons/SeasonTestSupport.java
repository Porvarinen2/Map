package fi.tesles.seasons;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonDirector;
import fi.tesles.seasons.sector.SeasonFrame;
import java.util.ArrayList;
import java.util.List;

/** Shared helpers for the pure-logic season contract suites. No Minecraft world required. */
public final class SeasonTestSupport {
   public static final long SEED = 7302026L;

   /** The calendar cycle order: Summer -> Autumn -> Winter -> Spring -> Summer. */
   public static final Season[] CYCLE = {Season.SUMMER, Season.AUTUMN, Season.WINTER, Season.SPRING};

   public static final CalendarPhase[] PHASES = {
      CalendarPhase.INCOMING, CalendarPhase.STABLE, CalendarPhase.OUTGOING
   };

   /** The checkpoint grid required by the spec: every phase at these progress values. */
   public static final float[] CHECKPOINTS = {0.0F, 0.01F, 0.10F, 0.25F, 0.50F, 0.75F, 0.99F, 1.0F};

   private SeasonTestSupport() {
   }

   public static SeasonFrame frame(Season season, CalendarPhase phase, float progress) {
      return SeasonDirector.derive(snapshot(season, phase, progress));
   }

   public static SeasonSnapshot snapshot(Season season, CalendarPhase phase, float progress) {
      return new SeasonSnapshot(
         season, previous(season), next(season), phase, progress,
         1.5F, 0.0F, 1.0F, 1.0F, 0.0F, 0.0F, 0.0F, 0.0F, 1.0F, 0.75F, 1.0F,
         false, false, 2026, 8, 15, SEED, 0
      );
   }

   /** All 12 (season, phase) pairs in calendar cycle order. */
   public static List<PhaseRef> cycle() {
      List<PhaseRef> out = new ArrayList<>(12);
      for (Season season : CYCLE) {
         for (CalendarPhase phase : PHASES) {
            out.add(new PhaseRef(season, phase));
         }
      }
      return out;
   }

   public static Season next(Season season) {
      return switch (season) {
         case SUMMER -> Season.AUTUMN;
         case AUTUMN -> Season.WINTER;
         case WINTER -> Season.SPRING;
         case SPRING -> Season.SUMMER;
      };
   }

   public static Season previous(Season season) {
      return switch (season) {
         case SUMMER -> Season.SPRING;
         case AUTUMN -> Season.SUMMER;
         case WINTER -> Season.AUTUMN;
         case SPRING -> Season.WINTER;
      };
   }

   public record PhaseRef(Season season, CalendarPhase phase) {
      @Override
      public String toString() {
         return season + " " + phase;
      }
   }
}
