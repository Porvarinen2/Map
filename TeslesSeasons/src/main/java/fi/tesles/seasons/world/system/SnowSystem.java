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
   /**
    * How much retreating coverage each snow layer is given to melt away in.
    *
    * <p>Winter Outgoing brings footprint and depth down together, as the specification's canonical
    * mapping requires. Applied literally per column that means a column standing under four layers
    * of snow drops to bare ground the instant the retreating footprint passes it, so the thaw reads
    * as holes being punched through full-depth snow with grass at the bottom of them, rather than
    * as snow melting.
    *
    * <p>Giving each layer its own slice of coverage makes a column come down one layer at a time -
    * 4/8, 3/8, 2/8, 1/8, ground - and makes the melt window proportional to how deep the snow is,
    * so deep snow takes proportionally longer to go than a dusting.
    *
    * <p>The value has to be at least the revision quantum, 1/100 per channel, or a column could
    * still lose more than one layer between two updates and the cliff would be back. Two percent
    * gives half a layer per update at the very most.
    */
   private static final float LAYER_MELT_BAND = 0.02F;

   public static int targetLayers(SeasonFrame frame, int x, int z, long seed) {
      float coverage = frame.snowCoverageTarget();
      float depth = frame.snowDepthTarget();
      if (coverage <= 0.0F || depth <= 0.0F) {
         return 0;
      }

      float field = SeasonCoordinateField.snowCoverage01(x, z, seed);
      if (field >= coverage) {
         return 0;
      }

      float target = Math.max(0.0F, Math.min(8.0F, depth * 8.0F));

      // Only the thaw is feathered. Growth must not be: Autumn Outgoing lays down a footprint at
      // exactly 1/8, and thinning its leading edge would leave part of that footprint bare and
      // pull the phase off its canonical coverage.
      if (frame.snowThawing()) {
         // No guard on full coverage. Gating the feather off while coverage was still 1.0 meant the
         // outermost columns were at full depth right up to the revision that took them out of the
         // footprint, so the melt opened with a ring of full-depth holes before settling down.
         // Winter Outgoing is the thaw: a depth gradient across the edge is what it should look
         // like from its first tick.
         target = Math.min(target, (coverage - field) / LAYER_MELT_BAND);
      }
      int base = (int)Math.floor(target);
      float fractional = target - base;
      int layers = base + (SeasonCoordinateField.snowDepth01(x, z, seed) < fractional ? 1 : 0);

      // A column inside the footprint always keeps at least its last layer. Feathering decides how
      // fast a column comes down through its layers, never whether it is still snowy - that stays
      // the footprint's decision alone, so the phase keeps exactly the coverage the specification
      // asks for, and the final step a player sees is 1/8 giving way to ground rather than a
      // full-depth column disappearing at once.
      if (layers < 1) {
         layers = 1;
      }

      return Math.min(8, layers);
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
      // Any snow-layer block, rather than the two this mod happens to know by name. That covers
      // vanilla snow and the slab-mounted variant - which extends SnowLayerBlock - without this
      // predicate having to touch block registration, and it catches other mods' snow layers too.
      return state != null && state.getBlock() instanceof SnowLayerBlock;
   }

   public static int layers(BlockState state) {
      return isSnowLayer(state) && state.hasProperty(SnowLayerBlock.LAYERS) ? (Integer)state.getValue(SnowLayerBlock.LAYERS) : 0;
   }
}
