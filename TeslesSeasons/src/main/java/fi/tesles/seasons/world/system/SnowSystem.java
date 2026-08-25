package fi.tesles.seasons.world.system;

import fi.tesles.seasons.block.TeslesSeasonBlocks;
import fi.tesles.seasons.world.SeasonalBlockClassifier;
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

   /**
    * Layers of seasonal snow this column should carry, or 0 for none.
    *
    * <p>Reads the frame's <em>quantised</em> snow channels so that every consumer - the server
    * placing blocks, the Voxy LOD projector and the shader - computes the same answer for the
    * whole life of a revision, rather than drifting apart as the clock advances between updates.
    */
   public static int targetLayers(SeasonFrame frame, int x, int z, long seed) {
      float coverage = frame.snowCoverageTarget();
      float depth = frame.snowDepthTarget();
      if (coverage <= 0.0F || depth <= 0.0F) {
         return 0;
      } else if (SeasonCoordinateField.snowCoverage01(x, z, seed) >= coverage) {
         return 0;
      } else {
         float target = Math.max(0.0F, Math.min(8.0F, depth * 8.0F));
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
    * Whether a snow layer can rest on this block, judged from the block state alone.
    *
    * <p>The server has a {@link net.minecraft.world.level.Level} and lets
    * {@code SnowLayerBlock.canSurvive} answer this. The Voxy LOD projector does not - it runs at
    * mesh-build time over packed voxels - so it needs the same answer from a state alone, and it
    * has to be the <em>same</em> answer or near and distant terrain disagree about where snow is.
    *
    * <p>Blocking motion stands in for a sturdy top face: true of terrain, stone, logs and roofs,
    * false of water, lava, grass and torches - the split canSurvive makes. Ice is excluded as
    * vanilla excludes it. Foliage is excluded because the server locates a column's surface with
    * the {@code MOTION_BLOCKING_NO_LEAVES} heightmap, which never reports a canopy as ground;
    * a projector that let snow settle on leaves grew a lid of snow over distant forest.
    */
   public static boolean canRestOn(BlockState state) {
      if (state == null || state.isAir()) {
         return false;
      }
      if (state.liquid() || !state.getFluidState().isEmpty()) {
         return false;
      }
      if (state.is(Blocks.ICE) || state.is(Blocks.PACKED_ICE) || state.is(Blocks.BARRIER)) {
         return false;
      }
      if (SeasonalBlockClassifier.isAnyLeaf(state)) {
         return false;
      }
      return state.blocksMotion();
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
