package fi.tesles.seasons.client.voxy;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.render.SeasonalCategory;
import fi.tesles.seasons.client.render.SeasonalClassifier;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;

public final class VoxySeasonMutationFilter {
   private static final ThreadLocal<Boolean> SUPPRESS_NEXT_RAW_INGEST = ThreadLocal.withInitial(() -> false);

   private VoxySeasonMutationFilter() {
   }

   public static void prepare(BlockPos pos, BlockState oldState, BlockState newState) {
      if (TeslesSeasons.CONFIG != null && TeslesSeasons.CONFIG.suppressSeasonalVoxyReingest) {
         if (isSeasonalMutation(pos, oldState, newState)) {
            SUPPRESS_NEXT_RAW_INGEST.set(true);
         } else {
            SUPPRESS_NEXT_RAW_INGEST.remove();
         }
      } else {
         SUPPRESS_NEXT_RAW_INGEST.remove();
      }
   }

   public static boolean consumeRawIngestSuppression() {
      boolean result = SUPPRESS_NEXT_RAW_INGEST.get();
      SUPPRESS_NEXT_RAW_INGEST.remove();
      return result;
   }

   private static boolean isSeasonalMutation(BlockPos pos, BlockState oldState, BlockState newState) {
      SeasonSnapshot snapshot = ClientSeasonState.get();
      SeasonalCategory oldCategory = SeasonalClassifier.categoryFor(oldState);
      boolean leafRemoval = oldCategory == SeasonalCategory.DECIDUOUS_LEAVES
         && newState.isAir()
         && (snapshot.leafRetention() <= 0.001F || positionNoise(pos, snapshot.visualSeed()) > snapshot.leafRetention());
      return leafRemoval
         ? true
         : newState.isAir()
            && (
               oldCategory == SeasonalCategory.GROUND_VEGETATION
                  || oldCategory == SeasonalCategory.FLOWER
                  || oldCategory == SeasonalCategory.MUSHROOM
                  || oldCategory == SeasonalCategory.SNOW_REPLACEABLE_DECOR
            );
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
}
