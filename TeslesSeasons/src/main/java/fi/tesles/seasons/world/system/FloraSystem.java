package fi.tesles.seasons.world.system;

import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.SeasonalBlockClassifier;
import fi.tesles.seasons.world.SeasonalFloraKind;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.Property;

public final class FloraSystem {
   private FloraSystem() {
   }

   public static SeasonalFloraKind kind(BlockState state) {
      SeasonalFloraKind direct = TeslesPlantsAdapter.kind(state);
      if (direct != SeasonalFloraKind.NONE) {
         return direct;
      } else {
         direct = TeslesFoodAdapter.kind(state);
         return direct != SeasonalFloraKind.NONE ? direct : SeasonalBlockClassifier.floraKind(state);
      }
   }

   public static boolean snowReplaceable(BlockState state) {
      if (!TeslesPlantsAdapter.isTeslesPlant(state) && !TeslesFoodAdapter.isSeasonalWildPlant(state)) {
         SeasonalFloraKind kind = kind(state);
         return kind == SeasonalFloraKind.PLANT || kind == SeasonalFloraKind.FLOWER || kind == SeasonalFloraKind.MUSHROOM;
      } else {
         return true;
      }
   }

   public static boolean shouldExist(SeasonalFloraKind kind, BlockPos pos, SeasonFrame frame, long seed) {
      if (kind == SeasonalFloraKind.NONE) {
         return true;
      } else {
         float retention = switch (kind) {
            case FLOWER -> frame.flowerRetention();
            case MUSHROOM -> frame.mushroomRetention();
            case PLANT -> frame.plantRetention();
            default -> 1.0F;
         };
         if (retention >= 0.9999F) {
            return true;
         } else {
            return retention <= 1.0E-4F ? false : SeasonCoordinateField.flora01(pos, seed) < retention;
         }
      }
   }

   public static BlockPos findSurfaceFlora(ServerLevel level, BlockPos ground) {
      for (int dy = 0; dy <= 4; dy++) {
         BlockPos p = ground.above(dy);
         if (snowReplaceable(level.getBlockState(p))) {
            return p;
         }
      }

      return null;
   }

   public static List<BlockPos> connectedVerticalParts(ServerLevel level, BlockPos pos, BlockState state) {
      String half = verticalHalf(state);
      if (half == null) {
         return List.of(pos);
      } else {
         BlockPos lower = pos;
         if ("upper".equals(half)) {
            lower = pos.below();
         }

         BlockState lowerState = level.getBlockState(lower);
         if (lowerState.getBlock() == state.getBlock() && "lower".equals(verticalHalf(lowerState))) {
            BlockPos upper = lower.above();
            BlockState upperState = level.getBlockState(upper);
            if (upperState.getBlock() == state.getBlock() && "upper".equals(verticalHalf(upperState))) {
               List<BlockPos> out = new ArrayList<>(2);
               out.add(lower);
               out.add(upper);
               return out;
            } else {
               return List.of(lower);
            }
         } else {
            return List.of(pos);
         }
      }
   }

   private static String verticalHalf(BlockState state) {
      for (Property<?> property : state.getProperties()) {
         String propertyName = property.getName();
         if ("half".equals(propertyName) || "part".equals(propertyName)) {
            Comparable<?> value = state.getValue(property);
            if (value != null) {
               String text = value.toString().toLowerCase(Locale.ROOT);
               if (!"lower".equals(text) && !"bottom".equals(text)) {
                  if (!"upper".equals(text) && !"top".equals(text)) {
                     continue;
                  }

                  return "upper";
               }

               return "lower";
            }
         }
      }

      return null;
   }
}
