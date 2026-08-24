package fi.tesles.seasons;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import fi.tesles.seasons.calendar.Season;
import java.io.IOException;
import java.io.Reader;
import java.io.Writer;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Month;
import java.time.ZoneId;
import java.util.LinkedHashMap;
import java.util.Map;
import net.fabricmc.loader.api.FabricLoader;

public final class TeslesSeasonsConfig {
   private static final Gson GSON = new GsonBuilder().setPrettyPrinting().create();
   private static final Path PATH = FabricLoader.getInstance().getConfigDir().resolve("teslesseasons.json");
   public String timeZone = "Europe/Helsinki";
   public int incomingTransitionDays = 7;
   public int outgoingTransitionDays = 7;
   public int calendarRefreshSeconds = 30;
   public int visualStepsPerTransition = 28;
   public long visualSeed = 7302026L;
   public Map<String, String> monthSeasons = defaultMonthSeasons();
   public double autumnLeafFallCompleteFraction = 0.68;
   public double springLeafReturnCompleteFraction = 0.6;
   public double autumnFlowerFallCompleteFraction = 0.78;
   public boolean mushroomsAutumnOnly = true;
   public boolean seasonalSnow = true;
   public double maximumPhysicalSnowCoverage = 1.0;
   public boolean plantSnowOverlay = true;
   public boolean migrateLegacy022Snow = true;
   public boolean winterSnowReplacesWildFlora = true;
   public int maximumAccumulatedSnowLayers = 8;
   public int surfaceColumnsPerTick = 1024;
   public int leafColumnsPerTick = 128;
   public int debugLeafColumnsPerTick = 512;
   public int columnsPerChunkSlice = 16;
   public int maxVisibleSnowWritesPerTick = 128;
   public int maxVisibleLeafWritesPerTick = 24;
   public int debugMaxVisibleLeafWritesPerTick = 96;
   public int maxVisibleLeafWritesPerChunkSlice = 48;
   public int debugImmediateLeafPriorityRadiusChunks = 6;
   public long worldReconcileBudgetMicros = 2200L;
   public long debugReconcileBudgetMicros = 3000L;
   public int canopyScanDepth = 128;
   public int materializationSteps = 24;
   public int backgroundReconcileRadiusChunks = 14;
   public int playerPriorityRadiusChunks = 12;
   public boolean preSendSeasonProjection = true;
   public boolean dynamicTreesSeasonManager = true;
   public boolean physicalDeciduousLeafFall = true;
   public boolean protectDormantDynamicTreeBranches = true;
   public boolean suppressDormantDynamicTreeLeafSpread = true;
   public double minimumWinterLeafRetention = 0.0;
   public boolean customWeatherSystem = true;
   public boolean historicalWeather = true;
   public int weatherEvaluationTicks = 100;
   public int weatherPatternMinutes = 20;
   public int debugWeatherPatternSeconds = 12;
   public boolean nearSeasonalTinting = true;
   public boolean nearVegetationFlattening = true;
   public double maximumGroundPlantFlattening = 0.14;
   public int nearRefreshRadiusChunks = 14;
   public int nearRefreshChunksPerTick = 2;
   public long nearRefreshBudgetMicros = 900L;
   public int debugNearRefreshChunksPerTick = 2;
   public long debugNearRefreshBudgetMicros = 1000L;
   public int debugVisualStepsPerTransition = 4;
   public boolean voxySeasonRendering = true;
   public double voxySnowBlendStartBlocks = 96.0;
   public double voxySnowBlendEndBlocks = 384.0;
   public boolean suppressSeasonalVoxyReingest = true;
   public boolean voxyServerAutoBackfillExistingRegions = true;

   public static TeslesSeasonsConfig load() {
      TeslesSeasonsConfig config = new TeslesSeasonsConfig();
      if (Files.isRegularFile(PATH)) {
         try (Reader reader = Files.newBufferedReader(PATH)) {
            TeslesSeasonsConfig read = (TeslesSeasonsConfig)GSON.fromJson(reader, TeslesSeasonsConfig.class);
            if (read != null) {
               config = read;
            }
         } catch (Exception var6) {
            TeslesSeasons.LOGGER.warn("Could not read {}, using safe defaults: {}", PATH, var6.toString());
         }
      }

      config.sanitize();
      config.save();
      return config;
   }

   public void save() {
      try {
         Files.createDirectories(PATH.getParent());

         try (Writer writer = Files.newBufferedWriter(PATH)) {
            GSON.toJson(this, writer);
         }
      } catch (IOException var6) {
         TeslesSeasons.LOGGER.warn("Could not save {}: {}", PATH, var6.toString());
      }
   }

   public ZoneId zoneId() {
      try {
         return ZoneId.of(this.timeZone);
      } catch (Exception var2) {
         return ZoneId.of("UTC");
      }
   }

   public Season seasonForMonth(Month month) {
      Season fallback = switch (month.getValue() - 1 & 3) {
         case 0 -> Season.SUMMER;
         case 1 -> Season.AUTUMN;
         case 2 -> Season.WINTER;
         default -> Season.SPRING;
      };
      return Season.parse(this.monthSeasons.get(month.name()), fallback);
   }

   private void sanitize() {
      if (this.monthSeasons == null) {
         this.monthSeasons = defaultMonthSeasons();
      }

      Map<String, String> repaired = defaultMonthSeasons();

      for (Month month : Month.values()) {
         Season parsed = Season.parse(this.monthSeasons.get(month.name()), null);
         if (parsed != null) {
            repaired.put(month.name(), parsed.name());
         }
      }

      this.monthSeasons = repaired;
      this.incomingTransitionDays = clamp(this.incomingTransitionDays, 1, 14);
      this.outgoingTransitionDays = clamp(this.outgoingTransitionDays, 1, 14);
      this.calendarRefreshSeconds = clamp(this.calendarRefreshSeconds, 5, 600);
      this.visualStepsPerTransition = clamp(this.visualStepsPerTransition, 7, 168);
      this.autumnLeafFallCompleteFraction = clamp(this.autumnLeafFallCompleteFraction, 0.45, 0.76);
      this.springLeafReturnCompleteFraction = clamp(this.springLeafReturnCompleteFraction, 0.35, 0.8);
      this.autumnFlowerFallCompleteFraction = clamp(this.autumnFlowerFallCompleteFraction, 0.6, 0.9);
      this.maximumPhysicalSnowCoverage = 1.0;
      this.maximumAccumulatedSnowLayers = clamp(this.maximumAccumulatedSnowLayers, 1, 8);
      this.surfaceColumnsPerTick = clamp(this.surfaceColumnsPerTick, 32, 8192);
      this.leafColumnsPerTick = clamp(this.leafColumnsPerTick, 8, 1024);
      this.debugLeafColumnsPerTick = clamp(this.debugLeafColumnsPerTick, this.leafColumnsPerTick, 2048);
      this.columnsPerChunkSlice = clamp(this.columnsPerChunkSlice, 1, 64);
      this.maxVisibleSnowWritesPerTick = clamp(this.maxVisibleSnowWritesPerTick, 16, 512);
      this.maxVisibleLeafWritesPerTick = clamp(this.maxVisibleLeafWritesPerTick, 8, 48);
      this.debugMaxVisibleLeafWritesPerTick = clamp(this.debugMaxVisibleLeafWritesPerTick, this.maxVisibleLeafWritesPerTick, 160);
      this.maxVisibleLeafWritesPerChunkSlice = clamp(this.maxVisibleLeafWritesPerChunkSlice, 8, this.debugMaxVisibleLeafWritesPerTick);
      this.debugImmediateLeafPriorityRadiusChunks = clamp(this.debugImmediateLeafPriorityRadiusChunks, 2, 10);
      this.worldReconcileBudgetMicros = clamp(this.worldReconcileBudgetMicros, 250L, 10000L);
      this.debugReconcileBudgetMicros = clamp(this.debugReconcileBudgetMicros, this.worldReconcileBudgetMicros, 15000L);
      this.canopyScanDepth = clamp(this.canopyScanDepth, 32, 256);
      this.materializationSteps = clamp(this.materializationSteps, 8, 64);
      this.backgroundReconcileRadiusChunks = clamp(this.backgroundReconcileRadiusChunks, 4, 24);
      this.playerPriorityRadiusChunks = clamp(this.playerPriorityRadiusChunks, 2, Math.min(16, this.backgroundReconcileRadiusChunks));
      this.weatherEvaluationTicks = clamp(this.weatherEvaluationTicks, 20, 1200);
      this.weatherPatternMinutes = clamp(this.weatherPatternMinutes, 2, 180);
      this.debugWeatherPatternSeconds = clamp(this.debugWeatherPatternSeconds, 3, 120);
      this.minimumWinterLeafRetention = 0.0;
      this.maximumGroundPlantFlattening = clamp(this.maximumGroundPlantFlattening, 0.0, 0.3);
      this.nearRefreshRadiusChunks = clamp(this.nearRefreshRadiusChunks, 2, 32);
      this.nearRefreshChunksPerTick = clamp(this.nearRefreshChunksPerTick, 1, 16);
      this.nearRefreshBudgetMicros = clamp(this.nearRefreshBudgetMicros, 100L, 5000L);
      this.debugNearRefreshChunksPerTick = clamp(this.debugNearRefreshChunksPerTick, 1, Math.min(2, this.nearRefreshChunksPerTick));
      this.debugNearRefreshBudgetMicros = clamp(this.debugNearRefreshBudgetMicros, this.nearRefreshBudgetMicros, 1200L);
      this.debugVisualStepsPerTransition = 4;
      this.voxySnowBlendStartBlocks = clamp(this.voxySnowBlendStartBlocks, 0.0, 1024.0);
      this.voxySnowBlendEndBlocks = clamp(this.voxySnowBlendEndBlocks, this.voxySnowBlendStartBlocks + 16.0, 4096.0);

      try {
         ZoneId.of(this.timeZone);
      } catch (Exception var7) {
         this.timeZone = "UTC";
      }
   }

   private static Map<String, String> defaultMonthSeasons() {
      Map<String, String> result = new LinkedHashMap<>();

      for (Month month : Month.values()) {
         Season season = switch (month.getValue() - 1 & 3) {
            case 0 -> Season.SUMMER;
            case 1 -> Season.AUTUMN;
            case 2 -> Season.WINTER;
            default -> Season.SPRING;
         };
         result.put(month.name(), season.name());
      }

      return result;
   }

   private static int clamp(int value, int min, int max) {
      return Math.max(min, Math.min(max, value));
   }

   private static long clamp(long value, long min, long max) {
      return Math.max(min, Math.min(max, value));
   }

   private static double clamp(double value, double min, double max) {
      return Math.max(min, Math.min(max, value));
   }
}
