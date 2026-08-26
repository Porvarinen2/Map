package fi.tesles.seasons.compat;

import fi.tesles.seasons.world.SeasonalBlockClassifier;
import fi.tesles.seasons.world.SeasonalFloraKind;
import fi.tesles.seasons.world.system.SnowSystem;
import net.minecraft.world.level.block.state.BlockState;

/**
 * Which direction a seasonal block change moves the world, relative to the neutral world.
 *
 * <p>The neutral world is the one Voxy's LOD database is supposed to hold: full canopy, full
 * ground flora, no seasonal snow. Season is applied when a section is meshed, never when it is
 * stored, so the store itself must stay neutral and the client's projector paints the current
 * season onto it.
 *
 * <h2>Why direction matters</h2>
 * The LOD store is only allowed to be written by changes that move the world <em>toward</em>
 * neutral. Blocking both directions - which is what a plain "is a season mutation in progress"
 * flag does - looks conservative and is in fact the opposite: it freezes each region's LOD at
 * whatever season happened to be running the first time that region's LOD was built. A forest
 * whose LOD was first built in winter then had no canopy and no way to ever gain one, because
 * the spring restoration that would have healed it was suppressed by the same flag that had
 * suppressed the autumn removal. Distant trees stayed bare for good, and distant ground kept the
 * snow it had when the player last stood there.
 *
 * <p>Letting the healing direction through makes the store self-correcting: over one year every
 * leaf is restored, every flower comes back and every snow layer melts, and each of those writes
 * is allowed to reach the LOD. Whatever season a region's LOD was born in, it converges on the
 * neutral world and stays there.
 */
public final class SeasonNeutrality {
   private SeasonNeutrality() {
   }

   /**
    * Whether this change takes the world further from the neutral world, and must therefore be
    * kept out of the LOD store.
    *
    * <p>Anything else - a leaf coming back, a flower returning, snow melting or thinning, or a
    * change that touches none of these - is allowed through, so the store can heal.
    */
   public static boolean movesAwayFromNeutral(BlockState before, BlockState after) {
      if (before == null || after == null) {
         return false;
      }

      // Seasonal snow appearing, or getting deeper.
      if (SnowSystem.isSnowLayer(after)) {
         if (!SnowSystem.isSnowLayer(before)) {
            return true;
         }
         if (SnowSystem.layers(after) > SnowSystem.layers(before)) {
            return true;
         }
      }

      // Canopy lost. Evergreen leaves are covered too: the neutral world holds every leaf, and
      // nothing seasonal should ever be the reason one is missing from the LOD.
      if (SeasonalBlockClassifier.isAnyLeaf(before) && !SeasonalBlockClassifier.isAnyLeaf(after)) {
         return true;
      }

      // Ground flora lost.
      return isFlora(before) && !isFlora(after);
   }

   /**
    * Whether this change brings the world back toward neutral, and so should reach the LOD store
    * even while the season system is the one making it.
    */
   public static boolean movesTowardNeutral(BlockState before, BlockState after) {
      if (before == null || after == null) {
         return false;
      }

      if (SnowSystem.isSnowLayer(before) && (!SnowSystem.isSnowLayer(after) || SnowSystem.layers(after) < SnowSystem.layers(before))) {
         return true;
      }

      if (!SeasonalBlockClassifier.isAnyLeaf(before) && SeasonalBlockClassifier.isAnyLeaf(after)) {
         return true;
      }

      return !isFlora(before) && isFlora(after);
   }

   private static boolean isFlora(BlockState state) {
      return state != null && !state.isAir() && SeasonalBlockClassifier.floraKind(state) != SeasonalFloraKind.NONE;
   }
}
