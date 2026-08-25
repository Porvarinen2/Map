package fi.tesles.seasons.client.voxy;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.render.SeasonalCategory;
import fi.tesles.seasons.client.render.SeasonalClassifier;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.system.LeafSystem;
import fi.tesles.seasons.world.system.SnowSystem;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.state.BlockState;

/**
 * Decides, client-side, whether a block change was the season doing its job.
 *
 * <p>Voxy's persistent LOD data must stay season-neutral: season is applied when a section is
 * meshed, never when it is stored. On a dedicated server the client has no access to the
 * server's mutation guard or its restore ledger, so it has to recognise seasonal changes from
 * the block change alone and keep them out of Voxy's ingest.
 *
 * <p>Getting this wrong is what "old season chunks that never go away" looks like: a seasonal
 * change that slips through is written into the LOD database as permanent terrain, and no
 * amount of remeshing later can remove it, because as far as Voxy is concerned that is simply
 * what the world looks like there.
 *
 * <h2>How a seasonal change is recognised</h2>
 * By asking the same deterministic coordinate field the server used to make the decision. If
 * the server removed a leaf because {@code leaf01(pos) >= leafRetention}, evaluating the same
 * function here gives the same answer. This must keep using the shared field rather than a
 * local copy: an earlier version hashed with no category salt while the server hashed with the
 * leaf salt, so the two disagreed at essentially every coordinate and the filter was close to
 * random.
 */
public final class VoxySeasonMutationFilter {
   private static final ThreadLocal<Boolean> SUPPRESS_NEXT_RAW_INGEST = ThreadLocal.withInitial(() -> false);

   private VoxySeasonMutationFilter() {
   }

   public static void prepare(BlockPos pos, BlockState oldState, BlockState newState) {
      if (TeslesSeasons.CONFIG != null
            && TeslesSeasons.CONFIG.suppressSeasonalVoxyReingest
            && isSeasonalMutation(pos, oldState, newState)) {
         SUPPRESS_NEXT_RAW_INGEST.set(true);
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
      SeasonFrame frame = ClientSeasonState.frame();
      long seed = ClientSeasonState.get().visualSeed();

      // Seasonal snow being placed or deepened. Only suppress when the new state is exactly
      // what the current frame asks for at this column: the season always writes the target
      // layer count, so an exact match is strong evidence, while a player stacking snow by
      // hand almost never lands on it.
      //
      // Snow being *removed* is deliberately not suppressed. Ingesting a removal writes
      // "no snow" into the LOD database, which restores neutrality rather than damaging it.
      if (SnowSystem.isSnowLayer(newState)) {
         int target = SnowSystem.targetLayers(frame, pos.getX(), pos.getZ(), seed);
         if (target > 0 && SnowSystem.layers(newState) == target) {
            return true;
         }
      }

      if (!newState.isAir()) {
         return false;
      }

      // Seasonal deciduous leaf drop: ask the same field the server used to drop it.
      SeasonalCategory oldCategory = SeasonalClassifier.categoryFor(oldState);
      if (oldCategory == SeasonalCategory.DECIDUOUS_LEAVES) {
         return !LeafSystem.shouldExist(pos, frame, seed);
      }

      // Seasonal flora removal. Flora is removed both by retention falling and by snow
      // burying the column, so any of these categories vanishing while the season is
      // actively removing flora is treated as seasonal.
      return switch (oldCategory) {
         case GROUND_VEGETATION, SNOW_REPLACEABLE_DECOR ->
            frame.plantRetention() < 0.9999F || frame.snowCoverage() > 0.0F;
         case FLOWER -> frame.flowerRetention() < 0.9999F || frame.snowCoverage() > 0.0F;
         case MUSHROOM -> frame.mushroomRetention() < 0.9999F || frame.snowCoverage() > 0.0F;
         default -> false;
      };
   }
}
