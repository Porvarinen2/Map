package fi.tesles.seasons.sector;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.TeslesSeasonsConfig;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.RealCalendarSeasonClock;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.debug.SeasonDebugController;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The one and only authority on the current season.
 *
 * <p>Clock/debug input selects a season module, the module produces an immutable
 * {@link SeasonFrame}, and every other subsystem projects that frame. Nothing else in the
 * mod is allowed to interpret the calendar.
 *
 * <p>The director also owns the monotonic frame revision. A revision is minted only when the
 * frame's <em>targets</em> actually change, so a Stable phase that asks the world for nothing
 * new never triggers a world pass.
 */
public final class SeasonDirector {
   private static final SeasonSector SPRING = new SpringSector();
   private static final SeasonSector SUMMER = new SummerSector();
   private static final SeasonSector AUTUMN = new AutumnSector();
   private static final SeasonSector WINTER = new WinterSector();

   private static final AtomicLong REVISION = new AtomicLong();
   private static volatile SeasonFrame current;

   private SeasonDirector() {
   }

   public static SeasonFrame currentFrame() {
      SeasonFrame frame = current;
      if (frame == null) {
         // Bootstrap fallback only: Summer / Stable / 50%. Replaced as soon as the calendar
         // resolves, via refresh().
         SeasonSnapshot raw = SeasonSnapshot.summerDefault(7302026L);
         frame = adopt(sector(raw.season()).frame(raw));
      }

      return frame;
   }

   /** Monotonic revision of the current frame; only meaningful for coalescing. */
   public static long revision() {
      return currentFrame().revision();
   }

   public static SeasonSnapshot refresh(long nowMillis) {
      TeslesSeasonsConfig config = TeslesSeasons.CONFIG;
      SeasonSnapshot raw = SeasonDebugController.calculate(nowMillis, config);
      if (raw == null) {
         raw = RealCalendarSeasonClock.calculateSummerStableBaseline(nowMillis, config);
      }

      SeasonFrame frame = adopt(sector(raw.season()).frame(raw));
      return frame.toLegacy(raw);
   }

   /** Pure derivation with no revision semantics; used by tests and read-only consumers. */
   public static SeasonFrame derive(SeasonSnapshot snapshot) {
      return sector(snapshot.season()).frame(snapshot);
   }

   public static void acceptRemote(SeasonSnapshot snapshot) {
      if (snapshot != null) {
         adopt(derive(snapshot));
      }
   }

   /**
    * Installs {@code candidate} as the current frame, minting a new revision only if it asks
    * for different targets than the frame already in place.
    */
   private static synchronized SeasonFrame adopt(SeasonFrame candidate) {
      SeasonFrame existing = current;
      if (existing != null && existing.sameTargets(candidate)) {
         return existing;
      }

      SeasonFrame promoted = candidate.withRevision(REVISION.incrementAndGet());
      current = promoted;
      return promoted;
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
