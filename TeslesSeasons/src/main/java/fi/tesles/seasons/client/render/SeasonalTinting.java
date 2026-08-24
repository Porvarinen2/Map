package fi.tesles.seasons.client.render;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import net.fabricmc.fabric.api.client.rendering.v1.BlockColorRegistry;
import net.minecraft.client.color.block.BlockTintSource;
import net.minecraft.client.renderer.BiomeColors;
import net.minecraft.client.renderer.block.BlockAndTintGetter;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;

public final class SeasonalTinting {
   private SeasonalTinting() {
   }

   public static void register() {
      Set<Block> foliage = new LinkedHashSet<>();
      Set<Block> grassLike = new LinkedHashSet<>();

      for (Block block : BuiltInRegistries.BLOCK) {
         BlockState state = block.defaultBlockState();
         SeasonalCategory category = SeasonalClassifier.categoryFor(state);
         if (category == SeasonalCategory.DECIDUOUS_LEAVES || category == SeasonalCategory.EVERGREEN_LEAVES) {
            foliage.add(block);
         } else if (category == SeasonalCategory.SEASONAL_GROUND) {
            grassLike.add(block);
         }
      }

      if (!foliage.isEmpty()) {
         BlockColorRegistry.register(List.of(new SeasonalTinting.FoliageTint()), foliage.toArray(Block[]::new));
      }

      if (!grassLike.isEmpty()) {
         BlockColorRegistry.register(List.of(new SeasonalTinting.GrassTint()), grassLike.toArray(Block[]::new));
      }
   }

   private static final class FoliageTint implements BlockTintSource {
      public int color(BlockState state) {
         return SeasonalColorUtil.opaque(7180101);
      }

      public int colorInWorld(BlockState state, BlockAndTintGetter level, BlockPos pos) {
         int base = level.getBlockTint(pos, BiomeColors.FOLIAGE_COLOR_RESOLVER);
         return SeasonalColorUtil.isVoxyCapture(level) ? SeasonalColorUtil.opaque(base) : SeasonalColorUtil.foliageColor(state, base);
      }
   }

   private static final class GrassTint implements BlockTintSource {
      public int color(BlockState state) {
         return SeasonalColorUtil.opaque(8365658);
      }

      public int colorInWorld(BlockState state, BlockAndTintGetter level, BlockPos pos) {
         int base = level.getBlockTint(pos, BiomeColors.GRASS_COLOR_RESOLVER);
         Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
         if (id != null) {
            String namespace = id.getNamespace().toLowerCase(Locale.ROOT);
            if (namespace.equals("teslesplants") || namespace.equals("teslesworldgenflora")) {
               base = SeasonalColorUtil.blend(16777215, base, 0.35F);
            }
         }

         return SeasonalColorUtil.isVoxyCapture(level) ? SeasonalColorUtil.opaque(base) : SeasonalColorUtil.grassColor(base);
      }
   }
}
