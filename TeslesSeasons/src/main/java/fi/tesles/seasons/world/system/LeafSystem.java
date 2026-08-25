package fi.tesles.seasons.world.system;

import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.SeasonalBlockClassifier;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;

public final class LeafSystem {
   private LeafSystem() {
   }

   public static boolean isDeciduous(BlockState state) {
      return SeasonalBlockClassifier.isDeciduousLeaf(state);
   }

   public static boolean shouldExist(BlockPos pos, SeasonFrame frame, long seed) {
      return shouldExist(pos.getX(), pos.getY(), pos.getZ(), frame, seed);
   }

   /** Allocation-free form, for scans that evaluate a whole section voxel by voxel. */
   public static boolean shouldExist(int x, int y, int z, SeasonFrame frame, long seed) {
      float retention = frame.leafRetention();
      if (retention >= 0.9999F) {
         return true;
      }
      return retention > 1.0E-4F && SeasonCoordinateField.leaf01(x, y, z, seed) < retention;
   }
}
