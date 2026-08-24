package fi.tesles.seasons.sector;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.TeslesSeasonsConfig;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.RealCalendarSeasonClock;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.debug.SeasonDebugController;

public final class SeasonDirector {
   private static final SeasonSector SPRING = new SpringSector();
   private static final SeasonSector SUMMER = new SummerSector();
   private static final SeasonSector AUTUMN = new AutumnSector();
   private static final SeasonSector WINTER = new WinterSector();
   private static volatile SeasonFrame current;

   private SeasonDirector() {
   }

   public static SeasonFrame currentFrame() {
      SeasonFrame frame = current;
      if (frame == null) {
         SeasonSnapshot raw = SeasonSnapshot.summerDefault(7302026L);
         frame = sector(raw.season()).frame(raw);
         current = frame;
      }

      return frame;
   }

   public static SeasonSnapshot refresh(long nowMillis) {
      TeslesSeasonsConfig config = TeslesSeasons.CONFIG;
      SeasonSnapshot raw = SeasonDebugController.calculate(nowMillis, config);
      if (raw == null) {
         raw = RealCalendarSeasonClock.calculateSummerStableBaseline(nowMillis, config);
      }

      SeasonFrame frame = sector(raw.season()).frame(raw);
      current = frame;
      return frame.toLegacy(raw);
   }

   public static SeasonFrame derive(SeasonSnapshot snapshot) {
      return sector(snapshot.season()).frame(snapshot);
   }

   public static void acceptRemote(SeasonSnapshot snapshot) {
      if (snapshot != null) {
         current = derive(snapshot);
      }
   }

   private static SeasonSector sector(Season season) {
      return switch (season) {
         case SPRING -> SPRING;
         case SUMMER -> SUMMER;
         case AUTUMN -> AUTUMN;
         case WINTER -> WINTER;
      };
   }
}
