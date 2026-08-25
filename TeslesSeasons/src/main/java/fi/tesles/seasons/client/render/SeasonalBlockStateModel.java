package fi.tesles.seasons.client.render;

import java.util.Locale;
import java.util.function.Predicate;
import net.fabricmc.fabric.api.client.model.loading.v1.wrapper.WrapperBlockStateModel;
import net.fabricmc.fabric.api.client.renderer.v1.mesh.QuadEmitter;
import net.minecraft.client.renderer.block.BlockAndTintGetter;
import net.minecraft.client.renderer.block.dispatch.BlockStateModel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SlabBlock;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;

public final class SeasonalBlockStateModel extends WrapperBlockStateModel {
   private final SeasonalCategory category;

   public SeasonalBlockStateModel(BlockStateModel wrapped, BlockState state, SeasonalCategory category) {
      super(wrapped);
      this.category = category;
   }

   public void emitQuads(QuadEmitter emitter, BlockAndTintGetter level, BlockPos pos, BlockState state, RandomSource random, Predicate<Direction> cullTest) {
      if (SeasonalColorUtil.isVoxyCapture(level)) {
         super.emitQuads(emitter, level, pos, state, random, cullTest);
      } else if (this.category == SeasonalCategory.SEASONAL_SNOW) {
         this.emitPhysicalSnow(emitter, level, pos, state, random, cullTest);
      } else {
         boolean seasonalPlant = this.category == SeasonalCategory.GROUND_VEGETATION || this.category == SeasonalCategory.FLOWER;
         boolean mushroom = this.category == SeasonalCategory.MUSHROOM;
         boolean crop = this.category == SeasonalCategory.SNOW_OVERLAY_PLANT;
         boolean decor = this.category == SeasonalCategory.SNOW_REPLACEABLE_DECOR;
         boolean plant = seasonalPlant || mushroom || crop || decor;
         boolean ground = this.category == SeasonalCategory.SEASONAL_GROUND;
         if (!plant && !ground) {
            super.emitQuads(emitter, level, pos, state, random, cullTest);
         } else {
            // The near renderer only applies colour here. It must never decide whether a
            // block exists: the server has already removed the flora this season does not
            // want, so hiding a block that is physically present would leave the player
            // walking into invisible plants and picking up items from thin air.
            //
            // It also never draws overlay snow. Seasonal snow is real SnowLayerBlock placed
            // by the server, so a painted-on layer would double it where both appear and
            // disagree with collision everywhere else.
            int multiplier = seasonalPlant
               ? SeasonalColorUtil.staticPlantMultiplier(this.category)
               : (ground ? SeasonalColorUtil.groundMultiplier() : -1);
            emitter.pushTransform(quad -> {
               quad.multiplyColor(multiplier);
               return true;
            });
            super.emitQuads(emitter, level, pos, state, random, cullTest);
            emitter.popTransform();
         }
      }
   }

   private void emitPhysicalSnow(
      QuadEmitter emitter, BlockAndTintGetter level, BlockPos pos, BlockState state, RandomSource random, Predicate<Direction> cullTest
   ) {
      BlockState below = level.getBlockState(pos.below());
      boolean onBottomSlab = state.is(Blocks.SNOW) && isBottomSlabState(below);
      if (onBottomSlab) {
         emitter.pushTransform(quad -> {
            for (int vertex = 0; vertex < 4; vertex++) {
               quad.pos(vertex, quad.x(vertex), quad.y(vertex) - 0.5F, quad.z(vertex));
            }

            return true;
         });
      }

      super.emitQuads(emitter, level, pos, state, random, cullTest);
      if (onBottomSlab) {
         emitter.popTransform();
      }
   }


   private static boolean isBottomSlabState(BlockState state) {
      return state != null && state.getBlock() instanceof SlabBlock && state.toString().toLowerCase(Locale.ROOT).contains("type=bottom");
   }







}
