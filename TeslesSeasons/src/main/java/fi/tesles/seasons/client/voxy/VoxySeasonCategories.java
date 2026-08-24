package fi.tesles.seasons.client.voxy;

import fi.tesles.seasons.client.render.SeasonalCategory;
import fi.tesles.seasons.client.render.SeasonalClassifier;
import fi.tesles.seasons.world.system.TeslesFoodAdapter;
import java.util.Locale;
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

   public static int categoryFor(BlockState state) {
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
