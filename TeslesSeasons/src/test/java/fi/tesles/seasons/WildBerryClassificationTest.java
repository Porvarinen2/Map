package fi.tesles.seasons;

import static org.junit.jupiter.api.Assertions.assertEquals;

import fi.tesles.seasons.world.SeasonalBlockClassifier;
import fi.tesles.seasons.world.SeasonalFloraKind;
import net.minecraft.SharedConstants;
import net.minecraft.resources.Identifier;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

/**
 * Wild berry bushes reach the berry channel whatever block class they extend.
 *
 * <p>A running server reported "1 berries" out of 1596 installed blocks. TeslesWorldGeneration's
 * eight wild bushes extend TeslesFood's historical crop block, so the crop guard classified them
 * as NONE before the berry rule was ever consulted and only {@code minecraft:sweet_berry_bush}
 * survived. The berry channel existed end to end and had almost nothing in it.
 *
 * <p>These cases pair a real vanilla block class with an injected identity, because the test
 * registry is frozen after bootstrap and cannot be given TeslesWorldGeneration's actual blocks.
 * The identity is what the rule keys on, so that is the part worth pinning.
 */
class WildBerryClassificationTest {
   @BeforeAll
   static void bootstrapMinecraft() {
      SharedConstants.tryDetectVersion();
      Bootstrap.bootStrap();
   }

   private static SeasonalFloraKind classify(String id, Block block) {
      return SeasonalBlockClassifier.classify(Identifier.parse(id), block);
   }

   @Test
   @DisplayName("a wild bush that extends CropBlock is still a berry")
   void cropDerivedWildBushIsBerry() {
      // Blocks.WHEAT is a CropBlock, standing in for TeslesFood's HistoricalCropBlock.
      for (String id : new String[]{
         "teslesworldgen:wild_raspberry_bush",
         "teslesworldgen:wild_blackberry_bush",
         "teslesworldgen:wild_blueberry_bush",
         "teslesworldgen:wild_elderberry_bush",
         "teslesworldgen:wild_juniper_berry_bush",
         "teslesworldgen:wild_hazelnut_bush",
         "teslesworldgen:wild_rosehip_bush",
         "teslesworldgen:wild_strawberry_bush",
         "teslesworldgenflora:wild_raspberry_bush"
      }) {
         assertEquals(SeasonalFloraKind.BERRY, classify(id, Blocks.WHEAT), id + " must be a berry");
      }
   }

   @Test
   @DisplayName("vanilla sweet berry bush is a berry")
   void sweetBerryBush() {
      assertEquals(SeasonalFloraKind.BERRY, classify("minecraft:sweet_berry_bush", Blocks.SWEET_BERRY_BUSH));
   }

   @Test
   @DisplayName("cultivated crops stay out of the berry channel")
   void cropsAreNotBerries() {
      // FarmSeasons owns these; seasonal flora must never remove and restore a player's field.
      for (Block block : new Block[]{Blocks.WHEAT, Blocks.CARROTS, Blocks.POTATOES, Blocks.BEETROOTS}) {
         Identifier id = net.minecraft.core.registries.BuiltInRegistries.BLOCK.getKey(block);
         assertEquals(SeasonalFloraKind.NONE, SeasonalBlockClassifier.classify(id, block), id + " must not be seasonal flora");
      }
   }

   @Test
   @DisplayName("a bush id that is not wild is not a berry")
   void nonWildBushesAreNotBerries() {
      // The rule is "wild_*_bush" in the worldgen namespaces, not "any bush".
      assertEquals(SeasonalFloraKind.NONE, classify("teslesworldgen:garden_raspberry_bush", Blocks.WHEAT));
      assertEquals(SeasonalFloraKind.NONE, classify("someothermod:wild_raspberry_bush", Blocks.WHEAT));
   }
}
