package fi.tesles.seasons.world;

import java.util.Locale;
import java.util.Set;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.BushBlock;
import net.minecraft.world.level.block.CropBlock;
import net.minecraft.world.level.block.LeavesBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;

public final class SeasonalBlockClassifier {
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

   private SeasonalBlockClassifier() {
   }

   public static boolean isDeciduousLeaf(BlockState state) {
      if (state == null || state.isAir()) {
         return false;
      }
      // Dynamic Trees ships several leaf block subclasses, not just DynamicLeavesBlock.
      // Classify all of them here so no other subsystem has to guess.
      if (isDynamicLeavesState(state)) {
         return !isEvergreen(state);
      }
      return isLeaf(state) && !isEvergreen(state);
   }

   public static boolean isDynamicDeciduousLeaf(BlockState state) {
      return isDynamicLeavesState(state) && !isEvergreen(state);
   }

   /**
    * Whether this is any Dynamic Trees leaf block.
    *
    * <p>Species classification is centralised here on purpose: matching only the exact
    * {@code DynamicLeavesBlock} class left every subclass unclassified, so those leaves were
    * silently treated as "not deciduous" and survived winter as floating foliage.
    */
   public static boolean isDynamicLeavesState(BlockState state) {
      if (state == null || state.isAir()) {
         return false;
      }
      try {
         if (state.getBlock().getClass().getName().startsWith("com.dtteam.dynamictrees.block.leaves.")) {
            return true;
         }
         Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
         if (id == null) {
            return false;
         }
         String namespace = id.getNamespace().toLowerCase(Locale.ROOT);
         String path = id.getPath().toLowerCase(Locale.ROOT);
         return "dynamictrees".equals(namespace)
            && (path.equals("leaves") || path.endsWith("_leaves") || path.startsWith("leaves_"));
      } catch (Throwable ignored) {
         return false;
      }
   }

   public static boolean isDynamicBranch(BlockState state) {
      if (state != null && !state.isAir()) {
         String className = state.getBlock().getClass().getName();
         return className.equals("com.dtteam.dynamictrees.block.branch.BranchBlock") || className.startsWith("com.dtteam.dynamictrees.block.branch.");
      } else {
         return false;
      }
   }

   public static boolean isEvergreen(BlockState state) {
      Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
      if (id == null) {
         return false;
      } else {
         String path = id.getPath().toLowerCase(Locale.ROOT);

         for (String word : EVERGREEN_WORDS) {
            if (path.contains(word)) {
               return true;
            }
         }

         return false;
      }
   }

   public static boolean isPersistentVanillaLeaf(BlockState state) {
      return state.getBlock() instanceof LeavesBlock
         && state.hasProperty(BlockStateProperties.PERSISTENT)
         && (Boolean)state.getValue(BlockStateProperties.PERSISTENT);
   }

   public static SeasonalFloraKind floraKind(BlockState state) {
      if (state != null && !state.isAir() && state.getFluidState().isEmpty()) {
         Block block = state.getBlock();
         if (block instanceof LeavesBlock || block instanceof CropBlock) {
            return SeasonalFloraKind.NONE;
         } else if (!isDynamicBranch(state) && !isLeaf(state)) {
            Identifier id = BuiltInRegistries.BLOCK.getKey(block);
            if (id == null) {
               return SeasonalFloraKind.NONE;
            } else {
               String namespace = id.getNamespace().toLowerCase(Locale.ROOT);
               String path = id.getPath().toLowerCase(Locale.ROOT);
               String simpleClass = block.getClass().getSimpleName().toLowerCase(Locale.ROOT);
               if (path.endsWith("_mushroom_block") || path.equals("mushroom_stem")) {
                  return SeasonalFloraKind.NONE;
               } else if (simpleClass.contains("slabmushroomproxy") || containsAny(path, FUNGUS_WORDS) || simpleClass.contains("mushroom")) {
                  return SeasonalFloraKind.MUSHROOM;
               } else if (simpleClass.contains("flower") || containsAny(path, FLOWER_WORDS)) {
                  return SeasonalFloraKind.FLOWER;
               } else if (namespace.equals("minecraft") && path.equals("moss_carpet")) {
                  return SeasonalFloraKind.PLANT;
               } else if (namespace.equals("minecraft") && path.equals("stone_button") && isFloorMounted(state)) {
                  return SeasonalFloraKind.PLANT;
               } else if (namespace.equals("teslesplants") || simpleClass.contains("slabplantproxy")) {
                  return SeasonalFloraKind.PLANT;
               } else if (containsAny(path, CROP_WORDS)) {
                  return SeasonalFloraKind.NONE;
               } else if (block instanceof BushBlock) {
                  return SeasonalFloraKind.PLANT;
               } else if (namespace.equals("minecraft") && isVanillaGroundPlant(path)) {
                  return SeasonalFloraKind.PLANT;
               } else {
                  return (namespace.equals("teslesworldgen") || namespace.equals("teslesworldgenflora")) && isWildPlant(path)
                     ? SeasonalFloraKind.PLANT
                     : SeasonalFloraKind.NONE;
               }
            }
         } else {
            return SeasonalFloraKind.NONE;
         }
      } else {
         return SeasonalFloraKind.NONE;
      }
   }

   private static boolean isLeaf(BlockState state) {
      if (state.getBlock() instanceof LeavesBlock) {
         return true;
      } else {
         String className = state.getBlock().getClass().getName();
         if (className.equals("com.dtteam.dynamictrees.block.leaves.DynamicLeavesBlock")) {
            return true;
         } else {
            Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
            if (id == null) {
               return false;
            } else {
               String path = id.getPath().toLowerCase(Locale.ROOT);
               return path.equals("leaves") || path.endsWith("_leaves") || path.startsWith("leaves_");
            }
         }
      }
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

   private static boolean isWildPlant(String path) {
      return path.startsWith("wild_")
         || path.endsWith("_grass")
         || path.endsWith("_flower")
         || path.endsWith("_bush")
         || path.endsWith("_herb")
         || path.endsWith("_plant");
   }

   private static boolean isFloorMounted(BlockState state) {
      String text = state.toString().toLowerCase(Locale.ROOT);
      return text.contains("face=floor") || text.contains("attach_face=floor");
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
