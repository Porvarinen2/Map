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
      if (frame.leafRetention() >= 0.9999F) {
         return true;
      } else {
         return frame.leafRetention() <= 1.0E-4F ? false : SeasonCoordinateField.leaf01(pos, seed) < frame.leafRetention();
      }
   }
}
