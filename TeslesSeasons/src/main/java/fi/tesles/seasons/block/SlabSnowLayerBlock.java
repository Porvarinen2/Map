package fi.tesles.seasons.block;

import net.minecraft.core.BlockPos;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.LevelReader;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.SlabBlock;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.BlockBehaviour.Properties;
import net.minecraft.world.level.block.state.properties.SlabType;
import net.minecraft.world.phys.shapes.CollisionContext;
import net.minecraft.world.phys.shapes.Shapes;
import net.minecraft.world.phys.shapes.VoxelShape;

public final class SlabSnowLayerBlock extends SnowLayerBlock {
   private static final VoxelShape[] LOWERED_SHAPES = createShapes(false);
   private static final VoxelShape[] LOWERED_COLLISION = createShapes(true);

   public SlabSnowLayerBlock(Properties properties) {
      super(properties);
   }

   private static VoxelShape[] createShapes(boolean collision) {
      VoxelShape[] shapes = new VoxelShape[9];

      for (int layers = 0; layers <= 8; layers++) {
         int effective = collision ? Math.max(0, layers - 1) : layers;
         double minY = -8.0;
         double maxY = -8.0 + effective * 2.0;
         shapes[layers] = effective == 0 ? Shapes.empty() : Block.column(16.0, minY, maxY);
      }

      return shapes;
   }

   protected VoxelShape getShape(BlockState state, BlockGetter level, BlockPos pos, CollisionContext context) {
      return LOWERED_SHAPES[state.getValue(LAYERS)];
   }

   protected VoxelShape getCollisionShape(BlockState state, BlockGetter level, BlockPos pos, CollisionContext context) {
      return LOWERED_COLLISION[state.getValue(LAYERS)];
   }

   protected VoxelShape getBlockSupportShape(BlockState state, BlockGetter level, BlockPos pos) {
      return LOWERED_SHAPES[state.getValue(LAYERS)];
   }

   protected VoxelShape getVisualShape(BlockState state, BlockGetter level, BlockPos pos, CollisionContext context) {
      return LOWERED_SHAPES[state.getValue(LAYERS)];
   }

   protected boolean canSurvive(BlockState state, LevelReader level, BlockPos pos) {
      BlockState below = level.getBlockState(pos.below());
      return below.getBlock() instanceof SlabBlock
         && below.hasProperty(SlabBlock.TYPE)
         && below.getValue(SlabBlock.TYPE) == SlabType.BOTTOM
         && below.getFluidState().isEmpty();
   }
}
