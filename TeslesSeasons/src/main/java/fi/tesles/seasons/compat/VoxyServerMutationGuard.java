package fi.tesles.seasons.compat;

import java.util.function.BooleanSupplier;

/**
 * Marks the block writes that must not reach VoxyServer's LOD store.
 *
 * <p>Only one direction is suppressed: changes that take the world away from the neutral world
 * Voxy is meant to hold. See {@link SeasonNeutrality} for why suppressing both directions
 * quietly froze each region's LOD at the season it was first built in.
 */
public final class VoxyServerMutationGuard {
   private static final ThreadLocal<Integer> DIVERGENCE_DEPTH = ThreadLocal.withInitial(() -> 0);

   private VoxyServerMutationGuard() {
   }

   /**
    * Runs a write that moves the world away from neutral, with the LOD store held back.
    *
    * <p>Writes that heal the store toward neutral must <em>not</em> be wrapped in this: they are
    * exactly the ones that need to get through.
    */
   public static boolean runSuppressingLodDivergence(BooleanSupplier action) {
      DIVERGENCE_DEPTH.set(DIVERGENCE_DEPTH.get() + 1);

      try {
         return action.getAsBoolean();
      } finally {
         int next = DIVERGENCE_DEPTH.get() - 1;
         if (next <= 0) {
            DIVERGENCE_DEPTH.remove();
         } else {
            DIVERGENCE_DEPTH.set(next);
         }
      }
   }

   /** Whether the write in progress on this thread must be kept out of the LOD store. */
   public static boolean isSuppressingAnySeasonalLodMutation() {
      return DIVERGENCE_DEPTH.get() > 0;
   }
}
