package fi.tesles.seasons.world.system;

import fi.tesles.seasons.world.SeasonalFloraKind;
import java.util.Set;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.state.BlockState;

public final class TeslesPlantsAdapter {
   private static final Set<String> MUSHROOMS = Set.of(
      "amethyst_deceiver",
      "bay_bolete",
      "birch_bolete",
      "birch_polypore",
      "cauliflower_fungus",
      "cep",
      "chanterelle",
      "common_puffball",
      "common_stinkhorn",
      "death_cap",
      "fairy_ring_champignon",
      "hedgehog_fungus",
      "honey_fungus",
      "morel",
      "orange_birch_bolete",
      "oyster_mushroom",
      "parasol_mushroom",
      "saffron_milk_cap",
      "shaggy_inkcap",
      "shaggy_parasol",
      "tinder_fungus",
      "turkey_tail"
   );

   private TeslesPlantsAdapter() {
   }

   public static boolean isTeslesPlant(BlockState state) {
      Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
      return id != null && "teslesplants".equals(id.getNamespace());
   }

   public static SeasonalFloraKind kind(BlockState state) {
      Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
      if (id != null && "teslesplants".equals(id.getNamespace())) {
         String p = id.getPath();
         if (MUSHROOMS.contains(p)
            || p.contains("mushroom")
            || p.contains("fungus")
            || p.contains("bolete")
            || p.contains("puffball")
            || p.contains("stinkhorn")
            || p.contains("inkcap")
            || p.contains("chanterelle")
            || p.contains("champignon")
            || p.contains("milk_cap")
            || p.contains("polypore")) {
            return SeasonalFloraKind.MUSHROOM;
         } else {
            return !p.contains("flower") && !p.contains("daisy") && !p.contains("poppy") && !p.contains("violet") && !p.contains("lavender")
               ? SeasonalFloraKind.PLANT
               : SeasonalFloraKind.FLOWER;
         }
      } else {
         return SeasonalFloraKind.NONE;
      }
   }
}
