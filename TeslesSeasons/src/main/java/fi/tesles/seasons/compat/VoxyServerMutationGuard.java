package fi.tesles.seasons.compat;

import java.util.function.BooleanSupplier;

public final class VoxyServerMutationGuard {
   private static final ThreadLocal<Integer> LEAF_REMOVAL_DEPTH = ThreadLocal.withInitial(() -> 0);
   private static final ThreadLocal<Integer> SURFACE_MUTATION_DEPTH = ThreadLocal.withInitial(() -> 0);
   private static final ThreadLocal<Integer> FLORA_REMOVAL_DEPTH = ThreadLocal.withInitial(() -> 0);

   private VoxyServerMutationGuard() {
   }

   public static boolean runSuppressingLeafRemoval(BooleanSupplier action) {
      return run(LEAF_REMOVAL_DEPTH, action);
   }

   public static boolean runSuppressingTransientSurfaceMutation(BooleanSupplier action) {
      return run(SURFACE_MUTATION_DEPTH, action);
   }

   public static boolean runSuppressingFloraRemoval(BooleanSupplier action) {
      return run(FLORA_REMOVAL_DEPTH, action);
   }

   public static boolean isSuppressingLeafRemoval() {
      return LEAF_REMOVAL_DEPTH.get() > 0;
   }

   public static boolean isSuppressingTransientSurfaceMutation() {
      return SURFACE_MUTATION_DEPTH.get() > 0;
   }

   public static boolean isSuppressingFloraRemoval() {
      return FLORA_REMOVAL_DEPTH.get() > 0;
   }

   public static boolean isSuppressingAnySeasonalLodMutation() {
      return isSuppressingLeafRemoval() || isSuppressingTransientSurfaceMutation() || isSuppressingFloraRemoval();
   }

   public static boolean isSuppressingVisualOnlyLodMutation() {
      return isSuppressingLeafRemoval() || isSuppressingFloraRemoval();
   }

   private static boolean run(ThreadLocal<Integer> depth, BooleanSupplier action) {
      depth.set(depth.get() + 1);

      boolean var2;
      try {
         var2 = action.getAsBoolean();
      } finally {
         int next = depth.get() - 1;
         if (next <= 0) {
            depth.remove();
         } else {
            depth.set(next);
         }
      }

      return var2;
   }
}
