package fi.tesles.seasons.fix069;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.sector.SeasonDirector;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.system.SnowSystem;

public final class ProportionalSeasonModel {
   private ProportionalSeasonModel() {
   }

   private static SeasonFrame f(SeasonSnapshot s) {
      return SeasonDirector.derive(s);
   }

   public static SeasonSnapshot apply(SeasonSnapshot s) {
      return s == null ? null : f(s).toLegacy(s);
   }

   public static float progress(SeasonSnapshot s) {
      return s == null ? 0.0F : clamp(s.phaseProgress());
   }

   public static float autumnColour(SeasonSnapshot s) {
      return s == null ? 0.0F : f(s).autumnColor();
   }

   public static float leafRetention(SeasonSnapshot s) {
      return s == null ? 1.0F : f(s).leafRetention();
   }

   public static float flowerRetention(SeasonSnapshot s) {
      return s == null ? 1.0F : f(s).flowerRetention();
   }

   public static float plantRetention(SeasonSnapshot s) {
      return s == null ? 1.0F : f(s).plantRetention();
   }

   public static float mushroomRetention(SeasonSnapshot s) {
      return s == null ? 1.0F : f(s).mushroomRetention();
   }

   public static float groundDormancy(SeasonSnapshot s) {
      return s == null ? 0.0F : f(s).groundDormancy();
   }

   public static float springFreshness(SeasonSnapshot s) {
      return s == null ? 0.0F : f(s).springFreshness();
   }

   public static float snowCoverage(SeasonSnapshot s) {
      return s == null ? 0.0F : f(s).snowCoverage();
   }

   public static int baseSnowLayers(SeasonSnapshot s) {
      if (s == null) {
         return 0;
      } else {
         float d = f(s).snowDepth();
         return d <= 0.0F ? 0 : Math.max(1, Math.min(8, Math.round(d * 8.0F)));
      }
   }

   public static float snowDepthFraction(SeasonSnapshot s) {
      return s == null ? 0.0F : f(s).snowDepth();
   }

   public static int snowLayersAt(SeasonSnapshot s, int x, int z) {
      return s == null ? 0 : SnowSystem.targetLayers(f(s), x, z, s.visualSeed());
   }

   public static boolean isSnowAccumulating(SeasonSnapshot s) {
      return s != null && f(s).snowAccumulating();
   }

   public static boolean isSnowThawing(SeasonSnapshot s) {
      return s != null && f(s).snowThawing();
   }

   public static int surfaceRevision(SeasonSnapshot s, int ignored) {
      if (s == null) {
         return 0;
      } else {
         SeasonFrame f = f(s);
         int h = s.season().ordinal() * 1000000
            + s.phase().ordinal() * 100000
            + Math.round(f.snowCoverage() * 100.0F) * 1000
            + Math.round(f.snowDepth() * 100.0F) * 10
            + Math.round(f.flowerRetention() * 9.0F);
         h = h * 101 + Math.round(f.plantRetention() * 100.0F);
         return h * 101 + Math.round(f.mushroomRetention() * 100.0F);
      }
   }

   private static float clamp(float x) {
      return Math.max(0.0F, Math.min(1.0F, x));
   }
}
