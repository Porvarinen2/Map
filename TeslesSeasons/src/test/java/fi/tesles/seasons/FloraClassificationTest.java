package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import fi.tesles.seasons.world.SeasonalBlockClassifier;
import fi.tesles.seasons.world.SeasonalFloraKind;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Classification against the real Minecraft block registry.
 *
 * <p>One registry decides what a block is and nothing else may guess, so this is the place
 * that decision gets checked. Misclassification is quiet and destructive in both directions:
 * a plant classified as NONE stands through the winter, and a block wrongly classified as
 * flora is removed from the world and restored from a ledger it never belonged in.
 */
class FloraClassificationTest {
   @BeforeAll
   static void bootstrapMinecraft() {
      SharedConstants.tryDetectVersion();
      Bootstrap.bootStrap();
   }

   private static SeasonalFloraKind kindOf(Block block) {
      return SeasonalBlockClassifier.floraKind(block.defaultBlockState());
   }

   @Test
   @DisplayName("vanilla flowers are flowers")
   void flowers() {
      for (Block b : new Block[]{
         Blocks.DANDELION, Blocks.POPPY, Blocks.BLUE_ORCHID, Blocks.ALLIUM, Blocks.AZURE_BLUET,
         Blocks.RED_TULIP, Blocks.OXEYE_DAISY, Blocks.CORNFLOWER, Blocks.LILY_OF_THE_VALLEY,
         Blocks.SUNFLOWER, Blocks.LILAC, Blocks.ROSE_BUSH, Blocks.PEONY, Blocks.PINK_PETALS
      }) {
         assertEquals(SeasonalFloraKind.FLOWER, kindOf(b), BuiltInRegistries.BLOCK.getKey(b) + " should be a flower");
      }
   }

   @Test
   @DisplayName("vanilla ground plants are plants")
   void groundPlants() {
      for (Block b : new Block[]{
         Blocks.SHORT_GRASS, Blocks.TALL_GRASS, Blocks.FERN, Blocks.LARGE_FERN, Blocks.DEAD_BUSH
      }) {
         assertEquals(SeasonalFloraKind.PLANT, kindOf(b), BuiltInRegistries.BLOCK.getKey(b) + " should be a plant");
      }
   }

   @Test
   @DisplayName("mushrooms are mushrooms, mushroom blocks and stems are not")
   void mushrooms() {
      assertEquals(SeasonalFloraKind.MUSHROOM, kindOf(Blocks.RED_MUSHROOM));
      assertEquals(SeasonalFloraKind.MUSHROOM, kindOf(Blocks.BROWN_MUSHROOM));
      // The big caps are structure, not seasonal flora: removing them would eat player builds.
      assertEquals(SeasonalFloraKind.NONE, kindOf(Blocks.RED_MUSHROOM_BLOCK));
      assertEquals(SeasonalFloraKind.NONE, kindOf(Blocks.BROWN_MUSHROOM_BLOCK));
      assertEquals(SeasonalFloraKind.NONE, kindOf(Blocks.MUSHROOM_STEM));
   }

   @Test
   @DisplayName("wild berry bushes get the berry channel")
   void berries() {
      assertEquals(SeasonalFloraKind.BERRY, kindOf(Blocks.SWEET_BERRY_BUSH));
   }

   @Test
   @DisplayName("crops are never seasonal flora")
   void cropsAreExcluded() {
      for (Block b : new Block[]{
         Blocks.WHEAT, Blocks.CARROTS, Blocks.POTATOES, Blocks.BEETROOTS
      }) {
         assertEquals(SeasonalFloraKind.NONE, kindOf(b),
            BuiltInRegistries.BLOCK.getKey(b) + " is farmland content, not seasonal flora");
      }
   }

   @Test
   @DisplayName("terrain, building blocks and leaves are never flora")
   void nonFloraIsNeverTouched() {
      for (Block b : new Block[]{
         Blocks.STONE, Blocks.DIRT, Blocks.GRASS_BLOCK, Blocks.OAK_LOG, Blocks.OAK_PLANKS,
         Blocks.COBBLESTONE, Blocks.BRICKS, Blocks.GLASS, Blocks.WATER, Blocks.LAVA,
         Blocks.OAK_LEAVES, Blocks.SPRUCE_LEAVES, Blocks.CHEST, Blocks.FURNACE, Blocks.SNOW
      }) {
         assertEquals(SeasonalFloraKind.NONE, kindOf(b),
            BuiltInRegistries.BLOCK.getKey(b) + " must never be treated as seasonal flora");
      }
   }

   @Test
   @DisplayName("leaves are classified as deciduous or evergreen, never both")
   void leafClassification() {
      assertTrue(SeasonalBlockClassifier.isDeciduousLeaf(Blocks.OAK_LEAVES.defaultBlockState()));
      assertTrue(SeasonalBlockClassifier.isDeciduousLeaf(Blocks.BIRCH_LEAVES.defaultBlockState()));
      assertTrue(SeasonalBlockClassifier.isDeciduousLeaf(Blocks.DARK_OAK_LEAVES.defaultBlockState()));
      // Evergreens keep their needles through winter.
      assertTrue(SeasonalBlockClassifier.isEvergreen(Blocks.SPRUCE_LEAVES.defaultBlockState()));
      assertTrue(!SeasonalBlockClassifier.isDeciduousLeaf(Blocks.SPRUCE_LEAVES.defaultBlockState()));
   }

   @Test
   @DisplayName("classification is stable and covers a plausible share of the registry")
   void registryWideSanity() {
      int flora = 0, total = 0;
      for (Block block : BuiltInRegistries.BLOCK) {
         BlockState state = block.defaultBlockState();
         SeasonalFloraKind first = SeasonalBlockClassifier.floraKind(state);
         // Memoised lookups must not drift from one call to the next.
         assertEquals(first, SeasonalBlockClassifier.floraKind(state),
            "unstable classification for " + BuiltInRegistries.BLOCK.getKey(block));
         if (first != SeasonalFloraKind.NONE) {
            flora++;
         }
         total++;
      }
      assertTrue(total > 1000, "expected the full block registry, got " + total);
      // Sanity band: vanilla has dozens of seasonal plants, but nothing like a third of the game.
      assertTrue(flora > 20, "suspiciously little flora classified: " + flora);
      assertTrue(flora < total / 4, "suspiciously much of the registry classified as flora: " + flora);
      System.out.println("classified " + flora + " seasonal flora blocks out of " + total);
   }
}
