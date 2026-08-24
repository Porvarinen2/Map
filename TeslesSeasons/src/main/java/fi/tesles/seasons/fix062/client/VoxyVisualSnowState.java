package fi.tesles.seasons.fix062.client;

import fi.tesles.seasons.client.ClientSeasonState;

public final class VoxyVisualSnowState {
   private static final float MAX_CHANGE_PER_SECOND = 0.016F;
   private static final float MAX_CHANGE_PER_TICK = 8.0000004E-4F;
   private static volatile float visualSnow = Float.NaN;
   private static int initialSnapTicks;

   private VoxyVisualSnowState() {
   }

   public static void resetForConnection() {
      visualSnow = Float.NaN;
      initialSnapTicks = 40;
   }

   public static void tick() {
      float target;
      try {
         target = clamp01(ClientSeasonState.get().snowCover());
      } catch (Throwable var3) {
         return;
      }

      float current = visualSnow;
      if (!Float.isNaN(current) && initialSnapTicks <= 0) {
         float delta = target - current;
         if (Math.abs(delta) <= 8.0000004E-4F) {
            visualSnow = target;
         } else {
            visualSnow = clamp01(current + Math.copySign(8.0000004E-4F, delta));
         }
      } else {
         visualSnow = target;
         if (initialSnapTicks > 0) {
            initialSnapTicks--;
         }
      }
   }

   public static float value() {
      float value = visualSnow;
      if (!Float.isNaN(value)) {
         return value;
      } else {
         try {
            return clamp01(ClientSeasonState.get().snowCover());
         } catch (Throwable var2) {
            return 0.0F;
         }
      }
   }

   private static float clamp01(float value) {
      return Math.max(0.0F, Math.min(1.0F, value));
   }
}
