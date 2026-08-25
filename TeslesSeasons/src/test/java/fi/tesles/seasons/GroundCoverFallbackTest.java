package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.world.SeasonalBlockClassifier;
import java.util.List;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Melting snow must never leave a column bare where a placeholder could stand.
 *
 * <p>Spring restores canonical flora gradually - it tracks the plant channel, so at 45% only 45%
 * of a column's real flora is back. The placeholder covers the remainder. A diagnostic capture of
 * a full year showed ordinary ground holding that placeholder in 1395 of 1395 sampled columns
 * while 64 of 131 slab-terrain columns sat as {@code minecraft:air} instead: the single vanilla
 * candidate cannot survive on a bottom slab and the code had nothing else to try.
 */
class GroundCoverFallbackTest {
   @BeforeAll
   static void bootstrapMinecraft() {
      SharedConstants.tryDetectVersion();
      Bootstrap.bootStrap();
   }

   @Test
   @DisplayName("vanilla ground cover is tried first")
   void vanillaFirst() {
      List<BlockState> candidates = SeasonalBlockClassifier.groundCoverCandidates();
      assertFalse(candidates.isEmpty(), "there must always be at least one candidate");
      assertSame(Blocks.SHORT_GRASS, candidates.get(0).getBlock(), "vanilla ground is the common case");
   }

   @Test
   @DisplayName("no candidate is null or air")
   void candidatesArePlaceable() {
      for (BlockState candidate : SeasonalBlockClassifier.groundCoverCandidates()) {
         assertNotNull(candidate, "a null candidate would be placed as a hole");
         assertFalse(candidate.isAir(), "air is the failure case, not a candidate");
      }
   }

   @Test
   @DisplayName("the candidate list is stable across calls")
   void stable() {
      // The reconciler asks per column, thousands of times per season change.
      List<BlockState> first = SeasonalBlockClassifier.groundCoverCandidates();
      List<BlockState> second = SeasonalBlockClassifier.groundCoverCandidates();
      assertEquals(first, second);
   }

   @Test
   @DisplayName("the slab candidate resolves to null rather than throwing when absent")
   void slabCandidateIsOptional() {
      // TeslesWorldGeneration is not on the test classpath, which is the same situation as a
      // player running TeslesSeasons without it. Resolution must degrade, not crash.
      assertTrue(SeasonalBlockClassifier.slabGroundCoverState() == null
         || !SeasonalBlockClassifier.slabGroundCoverState().isAir());
      assertEquals(SeasonalBlockClassifier.slabGroundCoverState(), SeasonalBlockClassifier.slabGroundCoverState());
   }
}
