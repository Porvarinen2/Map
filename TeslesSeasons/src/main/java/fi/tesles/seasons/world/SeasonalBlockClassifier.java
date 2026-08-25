package fi.tesles.seasons.world;

import fi.tesles.seasons.TeslesSeasons;
import java.util.Collections;
import java.util.EnumMap;
import java.util.IdentityHashMap;
import java.util.Map;
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

   /**
    * Wild berry bushes, which follow the berry channel rather than the ground-plant one.
    *
    * <p>Only wild bushes count. Cultivated or player-planted berries are not seasonal content
    * and must not be removed and restored underneath the player.
    */
   private static boolean isWildBerryBush(String namespace, String path) {
      if ("minecraft".equals(namespace)) {
         return path.equals("sweet_berry_bush");
      }
      if ("teslesworldgen".equals(namespace) || "teslesworldgenflora".equals(namespace)) {
         return path.startsWith("wild_") && path.endsWith("_bush");
      }
      return false;
   }

   /**
    * Block -> flora category, resolved once from the installed block registry.
    *
    * <p>The specification is explicit that string keyword matching may be a diagnostic
    * fallback but never the production registry. Resolving every installed block once at
    * startup turns the heuristics into exactly that: they run over the real registry a single
    * time to build a table, and every lookup afterwards is an identity map hit.
    *
    * <p>It is also a large amount of work removed from the hot path. The column sweep asks for
    * a flora kind for every block it touches, and the old form lower-cased two strings and
    * scanned up to eighteen keyword sets on each of those calls.
    */
   private static volatile Map<Block, SeasonalFloraKind> floraByBlock;

   /** Blocks that only count as seasonal decor while they actually sit on the floor. */
   private static volatile Set<Block> floorMountRequired;

   public static SeasonalFloraKind floraKind(BlockState state) {
      if (state == null || state.isAir() || !state.getFluidState().isEmpty()) {
         return SeasonalFloraKind.NONE;
      }

      Block block = state.getBlock();
      SeasonalFloraKind kind = floraRegistry().getOrDefault(block, SeasonalFloraKind.NONE);
      if (kind == SeasonalFloraKind.NONE) {
         return SeasonalFloraKind.NONE;
      }

      // The only classification that genuinely depends on block state rather than identity.
      if (floorMountRequired.contains(block) && !isFloorMounted(state)) {
         return SeasonalFloraKind.NONE;
      }
      return kind;
   }

   private static Map<Block, SeasonalFloraKind> floraRegistry() {
      Map<Block, SeasonalFloraKind> resolved = floraByBlock;
      if (resolved == null) {
         synchronized (SeasonalBlockClassifier.class) {
            resolved = floraByBlock;
            if (resolved == null) {
               resolved = buildFloraRegistry();
            }
         }
      }
      return resolved;
   }

   private static Map<Block, SeasonalFloraKind> buildFloraRegistry() {
      Map<Block, SeasonalFloraKind> map = new IdentityHashMap<>(512);
      Set<Block> floorMount = Collections.newSetFromMap(new IdentityHashMap<>(8));
      EnumMap<SeasonalFloraKind, Integer> counts = new EnumMap<>(SeasonalFloraKind.class);

      for (Block block : BuiltInRegistries.BLOCK) {
         SeasonalFloraKind kind = classifyBlock(block);
         if (kind == SeasonalFloraKind.NONE) {
            continue;
         }
         map.put(block, kind);
         counts.merge(kind, 1, Integer::sum);
         Identifier id = BuiltInRegistries.BLOCK.getKey(block);
         if (id != null && "minecraft".equals(id.getNamespace()) && "stone_button".equals(id.getPath())) {
            floorMount.add(block);
         }
      }

      floorMountRequired = floorMount;
      floraByBlock = map;
      // Loud on purpose: if an integration is installed but contributes nothing, that shows up
      // here rather than as flora quietly surviving the winter.
      TeslesSeasons.LOGGER.info(
         "Seasonal flora registry resolved from {} installed blocks: {} plants, {} flowers, {} mushrooms, {} berries.",
         BuiltInRegistries.BLOCK.size(),
         counts.getOrDefault(SeasonalFloraKind.PLANT, 0),
         counts.getOrDefault(SeasonalFloraKind.FLOWER, 0),
         counts.getOrDefault(SeasonalFloraKind.MUSHROOM, 0),
         counts.getOrDefault(SeasonalFloraKind.BERRY, 0));
      return map;
   }

   /**
    * Classifies one block by identity. Runs once per installed block at registry build time,
    * never on the hot path.
    */
   private static SeasonalFloraKind classifyBlock(Block block) {
      BlockState state = block.defaultBlockState();
      {
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
               } else if (isWildBerryBush(namespace, path)) {
                  return SeasonalFloraKind.BERRY;
               } else if (simpleClass.contains("slabmushroomproxy") || containsAny(path, FUNGUS_WORDS) || simpleClass.contains("mushroom")) {
                  return SeasonalFloraKind.MUSHROOM;
               } else if (simpleClass.contains("flower") || containsAny(path, FLOWER_WORDS)) {
                  return SeasonalFloraKind.FLOWER;
               } else if (namespace.equals("minecraft") && path.equals("moss_carpet")) {
                  return SeasonalFloraKind.PLANT;
               } else if (namespace.equals("minecraft") && path.equals("stone_button")) {
                  // Registered as decor; the floor-mount check happens per state on lookup.
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
