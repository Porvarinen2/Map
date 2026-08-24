package fi.tesles.seasons.world.system;

import fi.tesles.seasons.world.SeasonalFloraKind;
import java.util.Set;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.state.BlockState;

public final class TeslesFoodAdapter {
   private static final Set<String> WILD_BERRY_BLOCKS = Set.of(
      "blackberry", "blueberry", "elderberry", "juniper_berry", "raspberry", "rosehip", "wild_strawberry"
   );

   private TeslesFoodAdapter() {
   }

   public static boolean isSeasonalWildPlant(BlockState state) {
      Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
      if (id == null) {
         return false;
      } else {
         String namespace = id.getNamespace();
         String path = id.getPath();
         return "teslesfood".equals(namespace) && WILD_BERRY_BLOCKS.contains(path)
            ? true
            : "teslesworldgen".equals(namespace) && path.startsWith("wild_") && path.endsWith("_bush");
      }
   }

   public static SeasonalFloraKind kind(BlockState state) {
      return isSeasonalWildPlant(state) ? SeasonalFloraKind.PLANT : SeasonalFloraKind.NONE;
   }
}
