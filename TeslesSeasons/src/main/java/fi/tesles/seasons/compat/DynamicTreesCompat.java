package fi.tesles.seasons.compat;

import fi.tesles.seasons.SeasonEngine;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.Season;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.Level;

public final class DynamicTreesCompat {
   private static boolean installed;
   private static Method findRootNode;
   private static boolean rootLookupResolved;

   private DynamicTreesCompat() {
   }

   public static synchronized void installIfPresent() {
      if (!installed && TeslesSeasons.CONFIG.dynamicTreesSeasonManager) {
         if (FabricLoader.getInstance().isModLoaded("dynamictrees")) {
            try {
               ClassLoader loader = DynamicTreesCompat.class.getClassLoader();
               Class<?> managerInterface = Class.forName("com.dtteam.dynamictrees.api.season.SeasonManager", true, loader);
               Class<?> handlerClass = Class.forName("com.dtteam.dynamictrees.systems.season.SeasonCompatibilityHandler", true, loader);
               Class<?> climateClass = Class.forName("com.dtteam.dynamictrees.api.season.ClimateZoneType", true, loader);
               Object temperate = Enum.valueOf(climateClass.asSubclass(Enum.class), "TEMPERATE");
               InvocationHandler invocationHandler = (proxyx, method, args) -> invokeSeasonManager(proxyx, method, args, temperate);
               Object proxy = Proxy.newProxyInstance(loader, new Class[]{managerInterface}, invocationHandler);
               Method setter = handlerClass.getMethod("setSeasonManager", managerInterface);
               setter.invoke(null, proxy);
               installed = true;
               TeslesSeasons.LOGGER.info("Dynamic Trees real-calendar SeasonManager installed; dormant branch/root protection is available.");
            } catch (Throwable var8) {
               TeslesSeasons.LOGGER.warn("Dynamic Trees season bridge stayed inactive (API not compatible): {}", var8.toString());
            }
         }
      }
   }

   public static BlockPos findRoot(ServerLevel level, BlockPos pos) {
      if (!FabricLoader.getInstance().isModLoaded("dynamictrees")) {
         return null;
      } else {
         try {
            if (!rootLookupResolved) {
               synchronized (DynamicTreesCompat.class) {
                  if (!rootLookupResolved) {
                     Class<?> treeHelper = Class.forName("com.dtteam.dynamictrees.tree.TreeHelper", true, DynamicTreesCompat.class.getClassLoader());
                     findRootNode = treeHelper.getMethod("findRootNode", Level.class, BlockPos.class);
                     rootLookupResolved = true;
                  }
               }
            }

            if (findRootNode == null) {
               return null;
            } else {
               return findRootNode.invoke(null, level, pos) instanceof BlockPos blockPos ? blockPos : null;
            }
         } catch (Throwable var6) {
            rootLookupResolved = true;
            findRootNode = null;
            return null;
         }
      }
   }

   private static Object invokeSeasonManager(Object proxy, Method method, Object[] args, Object temperate) {
      SeasonSnapshot snapshot = SeasonEngine.current();
      return switch (method.getName()) {
         case "updateTick", "flushMappings", "clearCache" -> null;
         case "getGrowthFactor" -> snapshot.treeGrowthFactor();
         case "getSeedDropFactor" -> snapshot.seedDropFactor();
         case "getFruitProductionFactor" -> snapshot.fruitProductionFactor();
         case "getSeasonValue" -> snapshot.seasonCycleValue();
         case "getPeakFruitProductionSeasonValue" -> 1.5F;
         case "getClimate" -> temperate;
         case "shouldSnowMelt" -> snapshot.season() == Season.SPRING
               || snapshot.season() == Season.SUMMER
               || snapshot.snowThawing();
         case "toString" -> "TeslesRealCalendarSeasonManager";
         case "hashCode" -> System.identityHashCode(proxy);
         case "equals" -> args != null && args.length == 1 && proxy == args[0];
         default -> defaultValue(method.getReturnType());
      };
   }

   private static Object defaultValue(Class<?> type) {
      if (!type.isPrimitive()) {
         return null;
      } else if (type == boolean.class) {
         return false;
      } else if (type == byte.class) {
         return (byte)0;
      } else if (type == short.class) {
         return (short)0;
      } else if (type == int.class) {
         return 0;
      } else if (type == long.class) {
         return 0L;
      } else if (type == float.class) {
         return 0.0F;
      } else if (type == double.class) {
         return 0.0;
      } else {
         return type == char.class ? '\u0000' : null;
      }
   }
}
