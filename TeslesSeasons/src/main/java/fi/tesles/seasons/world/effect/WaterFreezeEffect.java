package fi.tesles.seasons.world.effect;

import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.system.SeasonCoordinateField;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.LiquidBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.level.material.Fluids;

/**
 * Still water freezes over as the ground frost comes in, and thaws with it.
 *
 * <p>This ships as a working effect and as the worked example of the extension point: it is the
 * whole of a seasonal world behaviour in one file, and it is registered in one line. Nothing in
 * the reconciler, the director, the season modules or the Voxy path knows it exists.
 *
 * <p>Worth reading for what it does <em>not</em> do. It keeps no state between ticks - the frame
 * says how much of the world should be frozen and the coordinate field says which part, so a
 * player who logs in mid-winter sees the same lake as one who watched it freeze. It never removes
 * ice it did not place, so a player's ice build survives the thaw. And it never asks how far
 * through winter we are, only how frozen the world should be now.
 */
public final class WaterFreezeEffect implements SeasonalWorldEffect {
   public static final String ID = "teslesseasons:water_freeze";

   /**
    * How much of the water surface is frozen at full ground frost.
    *
    * <p>Short of 1.0 on purpose: a lake with some open water reads as a lake in winter, where one
    * frozen edge to edge reads as a white floor.
    */
   private static final float MAXIMUM_COVERAGE = 0.92F;

   @Override
   public String id() {
      return ID;
   }

   @Override
   public boolean appliesTo(SeasonFrame frame) {
      // Winter freezes; Spring is when the ice this effect owns has to be given back. Outside
      // those the effect costs nothing at all.
      return frame.groundFrost() > 0.0F || frame.season() == Season.SPRING;
   }

   @Override
   public boolean applyToColumn(SeasonalEffectContext context) {
      BlockPos surface = context.surface();
      float coverage = context.frame().groundFrost() * MAXIMUM_COVERAGE;
      boolean wantIce = coverage > 0.0F
         && SeasonCoordinateField.effect01(context.x(), context.z(), context.seed(), SeasonCoordinateField.ICE_SALT) < coverage;

      // Give back what is no longer wanted first, so a column never holds both at once.
      for (BlockPos owned : context.ownedInColumn()) {
         if (!context.canWork()) {
            return false;
         }

         boolean keep = wantIce && owned.equals(surface);
         if (!keep && context.stateAt(owned).is(Blocks.ICE) && !context.restore(owned, sourceWater())) {
            return false;
         }
      }

      if (!wantIce) {
         return true;
      }

      BlockState state = context.stateAt(surface);
      if (!isFreezableWater(state) || !context.stateAt(surface.above()).isAir()) {
         return true;
      }

      return context.place(surface, Blocks.ICE.defaultBlockState());
   }

   /**
    * A full water source, and nothing else.
    *
    * <p>Flowing water is a stream, and freezing one leaves ice hanging where the current was.
    */
   private static boolean isFreezableWater(BlockState state) {
      return state.getBlock() instanceof LiquidBlock
         && state.getFluidState().getType() == Fluids.WATER
         && state.getFluidState().isSource();
   }

   private static BlockState sourceWater() {
      return Blocks.WATER.defaultBlockState().setValue(BlockStateProperties.LEVEL, 0);
   }
}
