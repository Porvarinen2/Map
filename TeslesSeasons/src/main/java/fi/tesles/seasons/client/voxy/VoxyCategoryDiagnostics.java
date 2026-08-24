package fi.tesles.seasons.client.voxy;

public final class VoxyCategoryDiagnostics {
   private static volatile int taggedStates;
   private static volatile int preservedConflicts;
   private static volatile int classifiedStates;
   private static volatile long lastUpdateMillis;

   private VoxyCategoryDiagnostics() {
   }

   public static void update(int tagged, int preserved, int classified) {
      taggedStates = tagged;
      preservedConflicts = preserved;
      classifiedStates = classified;
      lastUpdateMillis = System.currentTimeMillis();
   }

   public static String summary() {
      return "voxyCategories[tagged="
         + taggedStates
         + ",classified="
         + classifiedStates
         + ",conflicts="
         + preservedConflicts
         + ",updated="
         + lastUpdateMillis
         + "]";
   }
}
