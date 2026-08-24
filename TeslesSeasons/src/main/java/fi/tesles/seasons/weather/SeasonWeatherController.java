package fi.tesles.seasons.weather;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.debug.SeasonDebugController;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;

public final class SeasonWeatherController {
   private static TeslesWeatherType current = TeslesWeatherType.CLEAR;
   private static TeslesWeatherType pending = TeslesWeatherType.CLEAR;
   private static int pendingConfirmations;
   private static TeslesWeatherType forced;
   private static long lastEvaluationTick = Long.MIN_VALUE;
   private static long lastPatternSlot = Long.MIN_VALUE;
   private static double windX;
   private static double windZ;

   private SeasonWeatherController() {
   }

   public static void reset() {
      current = TeslesWeatherType.CLEAR;
      pending = TeslesWeatherType.CLEAR;
      pendingConfirmations = 0;
      forced = null;
      lastEvaluationTick = Long.MIN_VALUE;
      lastPatternSlot = Long.MIN_VALUE;
      windX = 0.0;
      windZ = 0.0;
   }

   public static WeatherSnapshot snapshot() {
      return new WeatherSnapshot(current, current.visualIntensity(), windX, windZ);
   }

   public static TeslesWeatherType currentWeather() {
      return current;
   }

   public static TeslesWeatherType forcedWeather() {
      return forced;
   }

   public static boolean isSnowing() {
      return current.isSnow();
   }

   public static void setForcedWeather(TeslesWeatherType type) {
      forced = type;
      pending = type == null ? current : type;
      pendingConfirmations = type == null ? 0 : 2;
      lastEvaluationTick = Long.MIN_VALUE;
      lastPatternSlot = Long.MIN_VALUE;
   }

   public static boolean tick(MinecraftServer server, long serverTick, long nowMillis, SeasonSnapshot season) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.customWeatherSystem) {
         long evalEvery = Math.max(20, TeslesSeasons.CONFIG.weatherEvaluationTicks);
         if (lastEvaluationTick != Long.MIN_VALUE && serverTick - lastEvaluationTick < evalEvery) {
            ensureVanillaAtmosphere(server, current);
            return false;
         } else {
            lastEvaluationTick = serverTick;
            TeslesWeatherType candidate;
            long slot;
            if (forced != null) {
               candidate = forced;
               slot = Long.MIN_VALUE + forced.ordinal();
            } else {
               long slotMillis = SeasonDebugController.isActive()
                  ? Math.max(3L, (long)TeslesSeasons.CONFIG.debugWeatherPatternSeconds) * 1000L
                  : Math.max(2L, (long)TeslesSeasons.CONFIG.weatherPatternMinutes) * 60000L;
               slot = Math.floorDiv(nowMillis, slotMillis);
               candidate = chooseWeather(season, slot);
            }

            boolean snapshotChanged = false;
            if (slot != lastPatternSlot) {
               lastPatternSlot = slot;
               updateWind(candidate, slot);
               snapshotChanged = true;
            }

            if (candidate != current) {
               boolean familyMismatch = candidate.isSnow() != current.isSnow() || candidate.isRain() != current.isRain();
               if (familyMismatch || forced != null) {
                  current = candidate;
                  pending = candidate;
                  pendingConfirmations = 2;
                  snapshotChanged = true;
               } else if (pending == candidate) {
                  pendingConfirmations++;
                  if (pendingConfirmations >= 2) {
                     current = candidate;
                     snapshotChanged = true;
                  }
               } else {
                  pending = candidate;
                  pendingConfirmations = 1;
               }
            } else {
               pending = current;
               pendingConfirmations = 2;
            }

            ensureVanillaAtmosphere(server, current);
            return snapshotChanged;
         }
      } else if (current != TeslesWeatherType.CLEAR) {
         current = TeslesWeatherType.CLEAR;
         windZ = 0.0;
         windX = 0.0;
         applyVanillaAtmosphere(server, current);
         return true;
      } else {
         return false;
      }
   }

   private static TeslesWeatherType chooseWeather(SeasonSnapshot season, long slot) {
      double signal = hash01(slot ^ (long)season.year() << 32 ^ (long)season.month() << 16 ^ season.dayOfMonth(), TeslesSeasons.CONFIG.visualSeed);
      boolean winterRegime = season.season() == Season.WINTER || season.snowCover() >= 0.2F;
      if (winterRegime) {
         if (signal < 0.18) {
            return TeslesWeatherType.CLEAR;
         } else if (signal < 0.28) {
            return TeslesWeatherType.CLOUDY;
         } else if (signal < 0.4) {
            return TeslesWeatherType.LIGHT_SNOW;
         } else if (signal < 0.58) {
            return TeslesWeatherType.SNOW;
         } else {
            return signal < 0.76 ? TeslesWeatherType.HEAVY_SNOW : TeslesWeatherType.BLIZZARD;
         }
      } else if (signal < 0.36) {
         return TeslesWeatherType.CLEAR;
      } else if (signal < 0.5) {
         return TeslesWeatherType.CLOUDY;
      } else if (signal < 0.59) {
         return TeslesWeatherType.DRIZZLE;
      } else if (signal < 0.74) {
         return TeslesWeatherType.RAIN;
      } else {
         return signal < 0.88 ? TeslesWeatherType.HEAVY_RAIN : TeslesWeatherType.THUNDERSTORM;
      }
   }

   private static void updateWind(TeslesWeatherType type, long slot) {
      double angle = hash01(slot * -7046029254386353131L + 7146057691288625177L, TeslesSeasons.CONFIG.visualSeed) * Math.PI * 2.0;
      double strength = type.windStrength() * (0.55 + 0.45 * hash01(slot ^ -3335678366873096957L, TeslesSeasons.CONFIG.visualSeed));
      windX = Math.cos(angle) * strength;
      windZ = Math.sin(angle) * strength;
   }

   private static void ensureVanillaAtmosphere(MinecraftServer server, TeslesWeatherType type) {
      ServerLevel level = server.overworld();
      boolean rain = type.isRain();
      boolean thunder = rain && type.thunder();
      if (level.isRaining() != rain || level.isThundering() != thunder) {
         applyVanillaAtmosphere(server, type);
      }
   }

   private static void applyVanillaAtmosphere(MinecraftServer server, TeslesWeatherType type) {
      boolean rain = type.isRain();
      boolean thunder = rain && type.thunder();
      server.setWeatherParameters(rain ? 0 : 24000, rain ? 24000 : 0, rain, thunder);
   }

   private static double hash01(long value, long seed) {
      long h = value ^ seed;
      h ^= h >>> 30;
      h *= -4658895280553007687L;
      h ^= h >>> 27;
      h *= -7723592293110705685L;
      h ^= h >>> 31;
      return (h >>> 11) * 1.110223E-16F;
   }
}
