package fi.tesles.seasons.sector;

import fi.tesles.seasons.calendar.Season;
import java.util.EnumMap;
import java.util.Map;

/**
 * Which module owns each season.
 *
 * <p>The four built-in modules are installed at class-init and can be replaced. Replacing one is
 * the supported way to change a season's shape - a mod, or a fork of this one, swaps in its own
 * {@link SeasonSector} and nothing else needs to know. {@link SeasonDirector} asks here rather
 * than naming the four implementations, so a season is data, not a branch in a switch.
 *
 * <p>A replacement is still bound by the contract the built-ins are held to: it must be a pure
 * function of the snapshot, and every continuous channel must leave a phase at exactly the value
 * the next phase enters with. {@code SeasonContinuityTest} runs against whatever is registered,
 * so a replacement that breaks continuity fails the build rather than the world.
 */
public final class SeasonRegistry {
   private static final Map<Season, SeasonSector> SECTORS = new EnumMap<>(Season.class);

   static {
      SECTORS.put(Season.SPRING, new SpringSector());
      SECTORS.put(Season.SUMMER, new SummerSector());
      SECTORS.put(Season.AUTUMN, new AutumnSector());
      SECTORS.put(Season.WINTER, new WinterSector());
   }

   private SeasonRegistry() {
   }

   /** Installs {@code sector} as the module for {@code season}, returning the one it replaced. */
   public static synchronized SeasonSector register(Season season, SeasonSector sector) {
      if (season == null || sector == null) {
         throw new IllegalArgumentException("season and sector are both required");
      }
      return SECTORS.put(season, sector);
   }

   public static SeasonSector get(Season season) {
      SeasonSector sector = SECTORS.get(season);
      if (sector == null) {
         throw new IllegalStateException("No season module registered for " + season);
      }
      return sector;
   }
}
