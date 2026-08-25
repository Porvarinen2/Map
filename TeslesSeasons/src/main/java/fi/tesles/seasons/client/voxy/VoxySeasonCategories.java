package fi.tesles.seasons.client.voxy;

import fi.tesles.seasons.client.render.SeasonalCategory;
import fi.tesles.seasons.client.render.SeasonalClassifier;
import fi.tesles.seasons.world.system.TeslesFoodAdapter;
import java.util.Locale;
import java.util.Set;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.state.BlockState;

public final class VoxySeasonCategories {
   private static final int MARKER_MASK = -1073741824;
   private static final int MARKER = 1073741824;
   private static final int CATEGORY_SHIFT = 26;
   private static final int ORIGINAL_MASK = 67108863;

   private VoxySeasonCategories() {
   }

   /** Vanilla blocks that are genuinely natural ground and may take a frost treatment. */
   private static final Set<String> VANILLA_NATURAL_GROUND = Set.of(
      "dirt", "coarse_dirt", "mud", "packed_mud", "sand", "red_sand", "gravel", "stone",
      "granite", "diorite", "andesite", "deepslate", "tuff", "calcite", "clay", "farmland"
   );

   private static final String[] NATURAL_TOKENS = {
      "dirt", "soil", "earth", "mud", "sand", "gravel", "ground", "peat", "silt", "loam",
      "scree", "clay", "rock", "stone", "tuff", "calcite"
   };

   private static final String[] CRAFTED_TOKENS = {
      "brick", "tile", "polished", "chiseled", "cut_", "wall", "stairs", "slab", "fence",
      "gate", "door", "trapdoor", "button", "pressure_plate", "lantern", "lamp", "planks",
      "board", "beam", "pillar", "column", "shingles", "roof", "cobble", "cobbled", "path",
      "road"
   };

   public static int categoryFor(BlockState state) {
      return sanitiseFrostable(state, rawCategoryFor(state));
   }

   /**
    * FROSTABLE_SURFACE is the fallback category for "some opaque block", so left alone it
    * frosts player builds - brick walls, roofs, planks - as readily as terrain. Restrict it
    * to blocks that actually read as natural ground.
    */
   private static int sanitiseFrostable(BlockState state, int category) {
      if (category != SeasonalCategory.FROSTABLE_SURFACE.voxyId() || state == null) {
         return category;
      }
      Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
      if (id == null) {
         return SeasonalCategory.NONE.voxyId();
      }
      String namespace = id.getNamespace().toLowerCase(Locale.ROOT);
      String path = id.getPath().toLowerCase(Locale.ROOT);
      boolean natural = "minecraft".equals(namespace)
         ? VANILLA_NATURAL_GROUND.contains(path) || path.endsWith("_terracotta")
         : containsAny(path, NATURAL_TOKENS) && !containsAny(path, CRAFTED_TOKENS);
      return natural ? category : SeasonalCategory.NONE.voxyId();
   }

   private static boolean containsAny(String text, String[] tokens) {
      for (String token : tokens) {
         if (text.contains(token)) {
            return true;
         }
      }
      return false;
   }

   private static int rawCategoryFor(BlockState state) {
      if (state == null) {
         return 0;
      } else if (TeslesFoodAdapter.isSeasonalWildPlant(state)) {
         return SeasonalCategory.GROUND_VEGETATION.voxyId();
      } else {
         SeasonalCategory category = SeasonalClassifier.categoryFor(state);
         if (category != SeasonalCategory.DECIDUOUS_LEAVES) {
            return category.voxyId();
         } else {
            Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
            String path = id == null ? "" : id.getPath().toLowerCase(Locale.ROOT);
            if (path.contains("birch")) {
               return 11;
            } else if (path.contains("dark_oak")) {
               return 12;
            } else if (path.contains("maple")) {
               return 13;
            } else if (path.contains("aspen")) {
               return 14;
            } else {
               return path.contains("oak") ? 15 : SeasonalCategory.DECIDUOUS_LEAVES.voxyId();
            }
         }
      }
   }

   public static boolean canAttachCategory(int customId) {
      return (customId & -67108864) == 0;
   }

   public static int attachCategory(int originalId, int category) {
      return category != 0 && canAttachCategory(originalId) ? originalId & 67108863 | 1073741824 | (category & 15) << 26 : originalId;
   }

   public static int markerMask() {
      return -1073741824;
   }

   public static int marker() {
      return 1073741824;
   }

   public static int originalMask() {
      return 67108863;
   }
}
