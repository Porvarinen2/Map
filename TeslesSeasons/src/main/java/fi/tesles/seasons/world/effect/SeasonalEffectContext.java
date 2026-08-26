package fi.tesles.seasons.world.effect;

import fi.tesles.seasons.sector.SeasonFrame;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.state.BlockState;

/**
 * One column, handed to a {@link SeasonalWorldEffect}.
 *
 * <p>Everything an effect needs to be correct is here, so that being correct is the easy path:
 * writes are budgeted, ownership is recorded for it, and the frame and seed it is given are the
 * same ones the snow, leaf and flora passes are working from. An effect that only ever calls
 * {@link #place} and {@link #restore} cannot damage a player's build, cannot overrun a tick, and
 * cannot disagree with the rest of the mod about what season it is.
 */
public interface SeasonalEffectContext {
   ServerLevel level();

   /** The frame every decision must be made against. Absolute targets, never deltas. */
   SeasonFrame frame();

   /** The world's visual seed. Pass it to the coordinate field; do not hash it yourself. */
   long seed();

   /** World X of this column. */
   int x();

   /** World Z of this column. */
   int z();

   /**
    * Highest position in the column that blocks motion, ignoring foliage - the ground.
    *
    * <p>The same position the snow pass calls the surface, so an effect and the snow agree about
    * where the world's top is even under a canopy.
    */
   BlockPos surface();

   BlockState stateAt(BlockPos pos);

   /**
    * Places a block and records it as this effect's, so it can be taken back later.
    *
    * @return {@code false} if the tick's budget is spent - return {@code false} from the effect
    */
   boolean place(BlockPos pos, BlockState state);

   /**
    * Puts back what was at {@code pos} before this effect claimed it, and releases the claim.
    *
    * <p>Does nothing, successfully, if this effect does not own the position - which is what stops
    * a thaw from eating ice a player put there.
    *
    * @return {@code false} if the tick's budget is spent
    */
   boolean restore(BlockPos pos, BlockState state);

   /** Whether this effect placed the block at {@code pos}. */
   boolean owns(BlockPos pos);

   /** Records {@code pos} as this effect's without writing a block. */
   void markOwned(BlockPos pos);

   /** Positions in this column this effect owns, for a sweep that has to undo its own work. */
   Iterable<BlockPos> ownedInColumn();

   /** False once the tick's budget is spent. Check it before a loop that could be long. */
   boolean canWork();
}
