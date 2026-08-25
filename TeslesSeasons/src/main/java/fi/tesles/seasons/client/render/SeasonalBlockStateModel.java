package fi.tesles.seasons.client.render;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.ClientSeasonState;
import java.util.Locale;
import java.util.function.Predicate;
import net.fabricmc.fabric.api.client.model.loading.v1.wrapper.WrapperBlockStateModel;
import net.fabricmc.fabric.api.client.renderer.v1.mesh.QuadEmitter;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.block.BlockAndTintGetter;
import net.minecraft.client.renderer.block.dispatch.BlockStateModel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.DoublePlantBlock;
import net.minecraft.world.level.block.SlabBlock;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;

public final class SeasonalBlockStateModel extends WrapperBlockStateModel {
   private final SeasonalCategory category;
   private final boolean flattenable;

   public SeasonalBlockStateModel(BlockStateModel wrapped, BlockState state, SeasonalCategory category) {
      super(wrapped);
      this.category = category;
      this.flattenable = !(state.getBlock() instanceof DoublePlantBlock);
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

   private static void emitSnowLayer(
      QuadEmitter emitter, BlockAndTintGetter level, BlockPos renderPos, RandomSource random, Predicate<Direction> cullTest, float yOffset
   ) {
      BlockState snow = Blocks.SNOW.defaultBlockState();
      BlockStateModel snowModel = Minecraft.getInstance().getModelManager().getBlockStateModelSet().get(snow);
      if (yOffset != 0.0F) {
         emitter.pushTransform(quad -> {
            for (int vertex = 0; vertex < 4; vertex++) {
               quad.pos(vertex, quad.x(vertex), quad.y(vertex) + yOffset, quad.z(vertex));
            }

            return true;
         });
      }

      snowModel.emitQuads(emitter, level, renderPos, snow, random, cullTest);
      if (yOffset != 0.0F) {
         emitter.popTransform();
      }
   }

   private static boolean isBottomSlabState(BlockState state) {
      return state != null && state.getBlock() instanceof SlabBlock && state.toString().toLowerCase(Locale.ROOT).contains("type=bottom");
   }

   private static boolean shouldRenderPlantSnow(BlockPos pos, SeasonSnapshot snapshot) {
      if (TeslesSeasons.CONFIG.plantSnowOverlay && TeslesSeasons.CONFIG.seasonalSnow) {
         float cover = snapshot.snowCover();
         if (cover <= 0.005F) {
            return false;
         } else {
            return cover >= 0.999F ? true : surfaceNoise(pos.getX(), pos.getZ(), snapshot.visualSeed()) < cover;
         }
      } else {
         return false;
      }
   }

   private static boolean shouldRenderGroundSnow(BlockAndTintGetter level, BlockPos pos) {
      if (TeslesSeasons.CONFIG.plantSnowOverlay && TeslesSeasons.CONFIG.seasonalSnow) {
         SeasonSnapshot snapshot = ClientSeasonState.get();
         float cover = snapshot.snowCover();
         if (cover <= 0.005F) {
            return false;
         } else {
            BlockPos abovePos = pos.above();
            BlockState above = level.getBlockState(abovePos);
            if (above.getBlock() instanceof SnowLayerBlock) {
               return false;
            } else if (!above.isAir()) {
               return false;
            } else {
               return cover >= 0.999F ? true : surfaceNoise(pos.getX(), pos.getZ(), snapshot.visualSeed()) < cover;
            }
         }
      } else {
         return false;
      }
   }

   private static boolean isUpperDoublePlant(BlockAndTintGetter level, BlockPos pos, BlockState state) {
      return state.getBlock() instanceof DoublePlantBlock && level.getBlockState(pos.below()).getBlock() == state.getBlock();
   }

   private static float positionNoise(BlockPos pos, long seed) {
      int h = pos.getX() * -1640531527 ^ pos.getY() * -2048144789 ^ pos.getZ() * -1028477387 ^ (int)seed;
      h ^= h >>> 16;
      h *= 2146121005;
      h ^= h >>> 15;
      h *= -2073254261;
      h ^= h >>> 16;
      return (h & 16777215) / 1.6777215E7F;
   }

   private static double surfaceNoise(int x, int z, long seed) {
      double broad = valueNoise(x, z, 37, seed ^ 2611923443488327891L);
      double medium = valueNoise(x, z, 13, seed ^ 1376283091369227076L);
      double fine = valueNoise(x, z, 5, seed ^ -6626703657320631856L);
      double jitter = hash01(x, z, seed ^ 589684135938649225L);
      return Math.max(0.0, Math.min(1.0, broad * 0.5 + medium * 0.3 + fine * 0.15 + jitter * 0.05));
   }

   private static double valueNoise(int x, int z, int scale, long seed) {
      int cellX = Math.floorDiv(x, scale);
      int cellZ = Math.floorDiv(z, scale);
      double fx = (double)Math.floorMod(x, scale) / scale;
      double fz = (double)Math.floorMod(z, scale) / scale;
      fx = fx * fx * (3.0 - 2.0 * fx);
      fz = fz * fz * (3.0 - 2.0 * fz);
      double n00 = hash01(cellX, cellZ, seed);
      double n10 = hash01(cellX + 1, cellZ, seed);
      double n01 = hash01(cellX, cellZ + 1, seed);
      double n11 = hash01(cellX + 1, cellZ + 1, seed);
      double nx0 = n00 + (n10 - n00) * fx;
      double nx1 = n01 + (n11 - n01) * fx;
      return nx0 + (nx1 - nx0) * fz;
   }

   private static double hash01(int x, int z, long seed) {
      long h = seed ^ x * -7046029254386353131L;
      h ^= z * -4417276706812531889L;
      h ^= h >>> 30;
      h *= -4658895280553007687L;
      h ^= h >>> 27;
      h *= -7723592293110705685L;
      h ^= h >>> 31;
      return (h >>> 11) * 1.110223E-16F;
   }
}
