package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.world.system.SnowSystem;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Where snow is allowed to rest, decided once for the server and the Voxy LOD projector alike.
 *
 * <p>The server gets this from {@code SnowLayerBlock.canSurvive}; the projector has no Level and
 * must reach the same verdict from a block state. When it did not, distant water grew a crust of
 * snow the physical world never had, and distant canopies were snowed over - and because the
 * projector strips winter leaves, that snow was left hanging in the air where the canopy had been,
 * still shading the ground under bare trees.
 */
class SnowSupportTest {
   @BeforeAll
   static void bootstrapMinecraft() {
      SharedConstants.tryDetectVersion();
      Bootstrap.bootStrap();
   }

   @Test
   @DisplayName("snow never rests on water or lava")
   void notOnFluids() {
      for (Block block : new Block[]{Blocks.WATER, Blocks.LAVA, Blocks.BUBBLE_COLUMN}) {
         assertFalse(SnowSystem.canRestOn(block.defaultBlockState()), block + " must not hold snow");
      }
   }

   @Test
   @DisplayName("snow never rests on foliage")
   void notOnLeaves() {
      for (Block block : new Block[]{
         Blocks.OAK_LEAVES, Blocks.BIRCH_LEAVES, Blocks.SPRUCE_LEAVES, Blocks.DARK_OAK_LEAVES,
         Blocks.JUNGLE_LEAVES, Blocks.ACACIA_LEAVES, Blocks.MANGROVE_LEAVES, Blocks.CHERRY_LEAVES,
         Blocks.AZALEA_LEAVES
      }) {
         assertFalse(SnowSystem.canRestOn(block.defaultBlockState()), block + " must not hold snow");
      }
   }

   @Test
   @DisplayName("snow never rests on ice, as vanilla decides")
   void notOnIce() {
      assertFalse(SnowSystem.canRestOn(Blocks.ICE.defaultBlockState()));
      assertFalse(SnowSystem.canRestOn(Blocks.PACKED_ICE.defaultBlockState()));
      assertFalse(SnowSystem.canRestOn(Blocks.BARRIER.defaultBlockState()));
   }

   @Test
   @DisplayName("snow never rests on air or on things it replaces")
   void notOnPassables() {
      assertFalse(SnowSystem.canRestOn(Blocks.AIR.defaultBlockState()));
      for (Block block : new Block[]{Blocks.SHORT_GRASS, Blocks.FERN, Blocks.DANDELION, Blocks.TORCH}) {
         assertFalse(SnowSystem.canRestOn(block.defaultBlockState()), block + " must not hold snow");
      }
   }

   @Test
   @DisplayName("snow rests on real ground and on solid built surfaces")
   void onGround() {
      for (Block block : new Block[]{
         Blocks.GRASS_BLOCK, Blocks.DIRT, Blocks.STONE, Blocks.GRAVEL, Blocks.SAND, Blocks.PODZOL,
         Blocks.COARSE_DIRT, Blocks.OAK_LOG, Blocks.OAK_PLANKS, Blocks.COBBLESTONE, Blocks.SNOW_BLOCK
      }) {
         assertTrue(SnowSystem.canRestOn(block.defaultBlockState()), block + " must hold snow");
      }
   }
}
