package fi.tesles.seasons.world.system;

import fi.tesles.seasons.block.TeslesSeasonBlocks;
import fi.tesles.seasons.sector.SeasonFrame;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SlabBlock;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.SlabType;

public final class SnowSystem {
   private SnowSystem() {
   }

   public static int targetLayers(SeasonFrame frame, int x, int z, long seed) {
      if (frame.snowCoverage() <= 0.0F || frame.snowDepth() <= 0.0F) {
         return 0;
      } else if (SeasonCoordinateField.snowCoverage01(x, z, seed) >= frame.snowCoverage()) {
         return 0;
      } else {
         float target = Math.max(0.0F, Math.min(8.0F, frame.snowDepth() * 8.0F));
         int base = (int)Math.floor(target);
         float fractional = target - base;
         int layers = base + (SeasonCoordinateField.snowDepth01(x, z, seed) < fractional ? 1 : 0);
         return Math.max(0, Math.min(8, layers));
      }
   }

   public static BlockState snowStateFor(ServerLevel level, BlockPos pos, int layers) {
      BlockState below = level.getBlockState(pos.below());
      boolean bottomSlab = below.getBlock() instanceof SlabBlock && below.hasProperty(SlabBlock.TYPE) && below.getValue(SlabBlock.TYPE) == SlabType.BOTTOM;
      BlockState snow = bottomSlab ? TeslesSeasonBlocks.SLAB_SNOW.defaultBlockState() : Blocks.SNOW.defaultBlockState();
      return (BlockState)snow.setValue(SnowLayerBlock.LAYERS, Math.max(1, Math.min(8, layers)));
   }

   /**
    * Whether this block is a snow layer the season system is capable of managing.
    *
    * <p>This is a <em>shape</em> test, not an ownership test. A player-placed snow layer
    * answers true here. Never remove or overwrite snow on the strength of this alone -
    * check the chunk's owned-snow ledger first, or seasonal cleanup will delete player
    * builds every spring.
    */
   public static boolean isSnowLayer(BlockState state) {
      return state.getBlock() == Blocks.SNOW || state.getBlock() == TeslesSeasonBlocks.SLAB_SNOW;
   }

   public static int layers(BlockState state) {
      return isSnowLayer(state) && state.hasProperty(SnowLayerBlock.LAYERS) ? (Integer)state.getValue(SnowLayerBlock.LAYERS) : 0;
   }
}
