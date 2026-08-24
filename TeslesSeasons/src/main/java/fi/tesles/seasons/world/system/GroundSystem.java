package fi.tesles.seasons.world.system;

import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;

public final class GroundSystem {
   private GroundSystem() {
   }

   public static boolean isImmutableGrass(BlockState state) {
      return state.is(Blocks.GRASS_BLOCK);
   }
}
