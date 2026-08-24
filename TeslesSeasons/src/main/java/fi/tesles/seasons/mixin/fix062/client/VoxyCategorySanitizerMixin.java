package fi.tesles.seasons.mixin.fix062.client;

import java.util.Locale;
import java.util.Set;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"fi.tesles.seasons.client.voxy.VoxySeasonCategories"},
   remap = false
)
public abstract class VoxyCategorySanitizerMixin {
   private static final Set<String> VANILLA_NATURAL = Set.of(
      "dirt",
      "coarse_dirt",
      "mud",
      "packed_mud",
      "sand",
      "red_sand",
      "gravel",
      "stone",
      "granite",
      "diorite",
      "andesite",
      "deepslate",
      "tuff",
      "calcite",
      "clay",
      "farmland"
   );
   private static final String[] NATURAL_TOKENS = new String[]{
      "dirt", "soil", "earth", "mud", "sand", "gravel", "ground", "peat", "silt", "loam", "scree", "clay", "rock", "stone", "tuff", "calcite"
   };
   private static final String[] CRAFTED_TOKENS = new String[]{
      "brick",
      "tile",
      "polished",
      "chiseled",
      "cut_",
      "wall",
      "stairs",
      "slab",
      "fence",
      "gate",
      "door",
      "trapdoor",
      "button",
      "pressure_plate",
      "lantern",
      "lamp",
      "planks",
      "board",
      "beam",
      "pillar",
      "column",
      "shingles",
      "roof",
      "cobble",
      "cobbled",
      "path",
      "road"
   };

   @Inject(
      method = {"categoryFor(Lnet/minecraft/world/level/block/state/BlockState;)I"},
      at = {@At("RETURN")},
      cancellable = true,
      remap = false,
      require = 0
   )
   private static void tesles$restrictGenericFrostable(BlockState state, CallbackInfoReturnable<Integer> cir) {
      Integer value = (Integer)cir.getReturnValue();
      if (value != null && value == 6 && state != null) {
         Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
         if (id == null) {
            cir.setReturnValue(0);
         } else {
            String namespace = id.getNamespace().toLowerCase(Locale.ROOT);
            String path = id.getPath().toLowerCase(Locale.ROOT);
            if ("minecraft".equals(namespace)) {
               boolean natural = VANILLA_NATURAL.contains(path) || path.endsWith("_terracotta");
               cir.setReturnValue(natural ? 6 : 0);
            } else {
               boolean natural = containsAny(path, NATURAL_TOKENS) && !containsAny(path, CRAFTED_TOKENS);
               cir.setReturnValue(natural ? 6 : 0);
            }
         }
      }
   }

   private static boolean containsAny(String text, String[] tokens) {
      for (String token : tokens) {
         if (text.contains(token)) {
            return true;
         }
      }

      return false;
   }
}
