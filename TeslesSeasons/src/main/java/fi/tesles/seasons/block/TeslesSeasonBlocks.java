package fi.tesles.seasons.block;

import fi.tesles.seasons.TeslesSeasons;
import java.util.function.Function;
import net.minecraft.core.Registry;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceKey;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockBehaviour.Properties;

public final class TeslesSeasonBlocks {
   public static final SlabSnowLayerBlock SLAB_SNOW = register("slab_snow", key -> new SlabSnowLayerBlock(Properties.ofFullCopy(Blocks.SNOW).setId(key)));

   private TeslesSeasonBlocks() {
   }

   public static void init() {
   }

   private static <T extends Block> T register(String path, Function<ResourceKey<Block>, T> factory) {
      ResourceKey<Block> key = ResourceKey.create(BuiltInRegistries.BLOCK.key(), TeslesSeasons.id(path));
      T block = (T)factory.apply(key);
      return (T)Registry.register(BuiltInRegistries.BLOCK, key, block);
   }
}
