package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.compat.SeasonNeutrality;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * The rule that decides which seasonal writes may reach Voxy's LOD store.
 *
 * <p>Only writes that heal the store toward the neutral world are allowed through. Suppressing
 * both directions - which a plain "a season mutation is happening" flag does - froze every
 * region's LOD at whatever season was running when that region's LOD was first built. A forest
 * whose LOD was born in winter had no canopy and no way to gain one, because the spring
 * restoration that would have healed it was blocked by the same flag that blocked the autumn
 * removal. Distant trees stayed bare across every following summer.
 */
class SeasonNeutralityTest {
   @BeforeAll
   static void bootstrapMinecraft() {
      SharedConstants.tryDetectVersion();
      Bootstrap.bootStrap();
   }

   private static BlockState snow(int layers) {
      return Blocks.SNOW.defaultBlockState().setValue(SnowLayerBlock.LAYERS, layers);
   }

   // Resolved lazily: block states cannot be built until Bootstrap has run, and static field
   // initialisers run when the class loads, which is before @BeforeAll.
   private static BlockState air() { return Blocks.AIR.defaultBlockState(); }
   private static BlockState leaf() { return Blocks.OAK_LEAVES.defaultBlockState(); }
   private static BlockState grass() { return Blocks.SHORT_GRASS.defaultBlockState(); }
   private static BlockState flower() { return Blocks.POPPY.defaultBlockState(); }
   private static BlockState ground() { return Blocks.GRASS_BLOCK.defaultBlockState(); }

   @Test
   @DisplayName("losing a leaf diverges; regaining one heals")
   void leaves() {
      assertTrue(SeasonNeutrality.movesAwayFromNeutral(leaf(), air()), "autumn leaf drop must stay out of the LOD");
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(air(), leaf()), "spring leaf restore must reach the LOD");
      assertTrue(SeasonNeutrality.movesTowardNeutral(air(), leaf()));
   }

   @Test
   @DisplayName("evergreen needles count as canopy too")
   void evergreenLeaves() {
      assertTrue(SeasonNeutrality.movesAwayFromNeutral(Blocks.SPRUCE_LEAVES.defaultBlockState(), air()));
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(air(), Blocks.SPRUCE_LEAVES.defaultBlockState()));
   }

   @Test
   @DisplayName("snow appearing or deepening diverges; melting and thinning heal")
   void snow() {
      assertTrue(SeasonNeutrality.movesAwayFromNeutral(air(), snow(1)), "first snow must stay out of the LOD");
      assertTrue(SeasonNeutrality.movesAwayFromNeutral(grass(), snow(3)), "snow burying flora must stay out");
      assertTrue(SeasonNeutrality.movesAwayFromNeutral(snow(2), snow(6)), "deepening must stay out");

      assertFalse(SeasonNeutrality.movesAwayFromNeutral(snow(6), snow(2)), "thinning must reach the LOD");
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(snow(1), air()), "melting must reach the LOD");
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(snow(1), grass()), "melting to a placeholder must reach the LOD");
      assertTrue(SeasonNeutrality.movesTowardNeutral(snow(1), grass()));
   }

   @Test
   @DisplayName("losing flora diverges; restoring it heals")
   void flora() {
      assertTrue(SeasonNeutrality.movesAwayFromNeutral(flower(), air()));
      assertTrue(SeasonNeutrality.movesAwayFromNeutral(grass(), air()));
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(air(), flower()));
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(air(), grass()));
      assertTrue(SeasonNeutrality.movesTowardNeutral(air(), flower()));
   }

   @Test
   @DisplayName("a whole year of writes leaves the store no worse than it started")
   void aYearHeals() {
      // Every write the season makes is one of these pairs. The ones allowed through are exactly
      // the ones that restore what the suppressed ones took away, so a store that begins in any
      // season converges on the neutral world rather than freezing where it started.
      BlockState[][] diverging = {{leaf(), air()}, {flower(), air()}, {grass(), air()}, {air(), snow(1)}, {snow(1), snow(4)}};
      BlockState[][] healing = {{air(), leaf()}, {air(), flower()}, {air(), grass()}, {snow(4), snow(1)}, {snow(1), air()}};
      for (BlockState[] pair : diverging) {
         assertTrue(SeasonNeutrality.movesAwayFromNeutral(pair[0], pair[1]), pair[0] + " -> " + pair[1]);
      }
      for (BlockState[] pair : healing) {
         assertFalse(SeasonNeutrality.movesAwayFromNeutral(pair[0], pair[1]), pair[0] + " -> " + pair[1]);
      }
   }

   @Test
   @DisplayName("changes that are not seasonal are never suppressed")
   void unrelatedWrites() {
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(ground(), ground()));
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(Blocks.STONE.defaultBlockState(), Blocks.COBBLESTONE.defaultBlockState()));
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(null, leaf()));
      assertFalse(SeasonNeutrality.movesAwayFromNeutral(leaf(), null));
   }
}
