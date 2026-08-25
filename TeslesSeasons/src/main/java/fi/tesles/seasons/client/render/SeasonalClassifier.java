package fi.tesles.seasons.client.render;

import java.util.Locale;
import java.util.Set;
import fi.tesles.seasons.world.SeasonalFloraKind;
import fi.tesles.seasons.world.system.TeslesPlantsAdapter;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.BushBlock;
import net.minecraft.world.level.block.CropBlock;
import net.minecraft.world.level.block.LeavesBlock;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;

public final class SeasonalClassifier {
   private static final Set<String> EVERGREEN_WORDS = Set.of("spruce", "pine", "fir", "cedar", "juniper", "yew", "hemlock", "redwood", "sequoia");
   private static final Set<String> FUNGUS_WORDS = Set.of(
      "mushroom",
      "fungus",
      "bolete",
      "polypore",
      "chanterelle",
      "puffball",
      "stinkhorn",
      "champignon",
      "morel",
      "inkcap",
      "deceiver",
      "oyster",
      "milk_cap",
      "death_cap",
      "parasol",
      "cep",
      "turkey_tail"
   );
   private static final Set<String> CROP_WORDS = Set.of(
      "wheat", "carrot", "potato", "beetroot", "crop", "cabbage", "onion", "tomato", "corn", "maize", "rye", "barley", "oat"
   );
   private static final Set<String> FLOWER_WORDS = Set.of(
      "flower",
      "dandelion",
      "poppy",
      "orchid",
      "allium",
      "bluet",
      "tulip",
      "daisy",
      "cornflower",
      "lily_of_the_valley",
      "sunflower",
      "lilac",
      "rose",
      "peony",
      "eyeblossom",
      "wildflowers",
      "pink_petals"
   );

   private SeasonalClassifier() {
   }

   public static SeasonalCategory categoryFor(BlockState state) {
      if (state != null && !state.isAir()) {
         // The TeslesPlants registry knows its own mushrooms exactly. Ask it before falling
         // back to the name/class heuristics below, which would otherwise file several
         // species as generic ground vegetation and leave them standing all winter.
         if (TeslesPlantsAdapter.kind(state) == SeasonalFloraKind.MUSHROOM) {
            return SeasonalCategory.MUSHROOM;
         }
         Block block = state.getBlock();
         if (block instanceof SnowLayerBlock) {
            return SeasonalCategory.SEASONAL_SNOW;
         } else {
            Identifier id = BuiltInRegistries.BLOCK.getKey(block);
            String namespace = id == null ? "" : id.getNamespace().toLowerCase(Locale.ROOT);
            String path = id == null ? "" : id.getPath().toLowerCase(Locale.ROOT);
            String simpleClass = block.getClass().getSimpleName().toLowerCase(Locale.ROOT);
            boolean dynamicLeaves = block.getClass().getName().equals("com.dtteam.dynamictrees.block.leaves.DynamicLeavesBlock")
               || namespace.equals("dynamictrees") && path.endsWith("_leaves");
            if (dynamicLeaves || block instanceof LeavesBlock || looksLikeLeaves(path)) {
               return containsAny(path, EVERGREEN_WORDS) ? SeasonalCategory.EVERGREEN_LEAVES : SeasonalCategory.DECIDUOUS_LEAVES;
            } else if (path.endsWith("_mushroom_block") || path.equals("mushroom_stem")) {
               return SeasonalCategory.NONE;
            } else if (simpleClass.contains("slabmushroomproxy") || containsAny(path, FUNGUS_WORDS) || simpleClass.contains("mushroom")) {
               return SeasonalCategory.MUSHROOM;
            } else if (looksLikeFlower(block, path)) {
               return SeasonalCategory.FLOWER;
            } else if (block instanceof CropBlock) {
               return SeasonalCategory.SNOW_OVERLAY_PLANT;
            } else if (namespace.equals("minecraft") && path.equals("moss_carpet")) {
               return SeasonalCategory.SNOW_REPLACEABLE_DECOR;
            } else if (namespace.equals("minecraft") && path.equals("stone_button") && isFloorMounted(state)) {
               return SeasonalCategory.SNOW_REPLACEABLE_DECOR;
            } else if (namespace.equals("teslesplants") || simpleClass.contains("slabplantproxy")) {
               return SeasonalCategory.GROUND_VEGETATION;
            } else if (containsAny(path, CROP_WORDS)) {
               return SeasonalCategory.SNOW_OVERLAY_PLANT;
            } else if (block instanceof BushBlock) {
               return SeasonalCategory.GROUND_VEGETATION;
            } else if (namespace.equals("minecraft") && isVanillaGroundPlant(path)) {
               return SeasonalCategory.GROUND_VEGETATION;
            } else if ((namespace.equals("teslesworldgen") || namespace.equals("teslesworldgenflora")) && isWildPlant(path)) {
               return SeasonalCategory.GROUND_VEGETATION;
            } else if (isSeasonalGround(namespace, path)) {
               return SeasonalCategory.SEASONAL_GROUND;
            } else {
               return state.getFluidState().isEmpty() ? SeasonalCategory.FROSTABLE_SURFACE : SeasonalCategory.NONE;
            }
         }
      } else {
         return SeasonalCategory.NONE;
      }
   }

   public static boolean isEvergreen(BlockState state) {
      Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
      return id != null && containsAny(id.getPath().toLowerCase(Locale.ROOT), EVERGREEN_WORDS);
   }

   public static int autumnLeafRgb(BlockState state) {
      Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
      String path = id == null ? "" : id.getPath().toLowerCase(Locale.ROOT);
      if (path.contains("birch")) {
         return 13674815;
      } else if (path.contains("dark_oak")) {
         return 8080430;
      } else if (path.contains("maple")) {
         return 12081714;
      } else if (path.contains("aspen")) {
         return 13084747;
      } else {
         return path.contains("oak") ? 10251060 : 10582077;
      }
   }

   private static boolean looksLikeLeaves(String path) {
      return path.equals("leaves") || path.endsWith("_leaves") || path.startsWith("leaves_");
   }

   private static boolean looksLikeFlower(Block block, String path) {
      String className = block.getClass().getSimpleName().toLowerCase(Locale.ROOT);
      return className.contains("flower") || containsAny(path, FLOWER_WORDS);
   }

   private static boolean isVanillaGroundPlant(String path) {
      return path.equals("short_grass")
         || path.equals("tall_grass")
         || path.equals("fern")
         || path.equals("large_fern")
         || path.equals("dead_bush")
         || path.equals("bush")
         || path.equals("sweet_berry_bush")
         || path.equals("firefly_bush")
         || path.equals("leaf_litter");
   }

   private static boolean isFloorMounted(BlockState state) {
      String text = state.toString().toLowerCase(Locale.ROOT);
      return text.contains("face=floor") || text.contains("attach_face=floor");
   }

   private static boolean isWildPlant(String path) {
      return path.startsWith("wild_") || path.endsWith("_grass") || path.endsWith("_flower") || path.endsWith("_bush");
   }

   private static boolean isSeasonalGround(String namespace, String path) {
      if (namespace.equals("minecraft")) {
         return path.equals("grass_block") || path.equals("podzol") || path.equals("dirt_path") || path.equals("rooted_dirt") || path.equals("moss_block");
      } else {
         return !namespace.equals("teslesworldgen")
            ? false
            : path.endsWith("_slab") || path.contains("grass") || path.contains("moss") || path.contains("podzol");
      }
   }

   private static boolean containsAny(String value, Set<String> words) {
      for (String word : words) {
         if (value.contains(word)) {
            return true;
         }
      }

      return false;
   }
}
