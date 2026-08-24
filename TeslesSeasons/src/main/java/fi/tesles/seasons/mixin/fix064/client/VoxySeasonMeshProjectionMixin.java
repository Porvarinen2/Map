package fi.tesles.seasons.mixin.fix064.client;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.voxy.VoxySeasonCategories;
import fi.tesles.seasons.fix061.OrganicSnowField;
import fi.tesles.seasons.fix064.client.VoxySeasonRemeshScheduler;
import fi.tesles.seasons.world.SeasonalBlockClassifier;
import fi.tesles.seasons.world.SeasonalFloraKind;
import it.unimi.dsi.fastutil.ints.Int2ByteOpenHashMap;
import me.cortex.voxy.client.core.rendering.building.BuiltSection;
import me.cortex.voxy.common.world.WorldEngine;
import me.cortex.voxy.common.world.WorldSection;
import me.cortex.voxy.common.world.other.Mapper;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.ModifyVariable;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.core.rendering.building.RenderDataFactory"},
   remap = false
)
public abstract class VoxySeasonMeshProjectionMixin {
   @Shadow
   @Final
   private WorldEngine world = null;
   @Unique
   private static final ThreadLocal<WorldSection> TESLES_SECTION = new ThreadLocal<>();

   @Inject(
      method = {"generateMesh(Lme/cortex/voxy/common/world/WorldSection;)Lme/cortex/voxy/client/core/rendering/building/BuiltSection;"},
      at = {@At("HEAD")},
      remap = false,
      require = 1
   )
   private void tesles$captureSection(WorldSection section, CallbackInfoReturnable<BuiltSection> cir) {
      TESLES_SECTION.set(section);
   }

   @Inject(
      method = {"generateMesh(Lme/cortex/voxy/common/world/WorldSection;)Lme/cortex/voxy/client/core/rendering/building/BuiltSection;"},
      at = {@At("RETURN")},
      remap = false,
      require = 1
   )
   private void tesles$clearSection(WorldSection section, CallbackInfoReturnable<BuiltSection> cir) {
      TESLES_SECTION.remove();
   }

   @ModifyVariable(
      method = {"prepareSectionData([J)I"},
      at = @At("HEAD"),
      argsOnly = true,
      ordinal = 0,
      remap = false,
      require = 1
   )
   private long[] tesles$projectSeasonGeometry(long[] raw) {
      WorldSection section = TESLES_SECTION.get();
      SeasonSnapshot snapshot = ClientSeasonState.get();
      if (section == null || snapshot == null || raw == null || raw.length != 32768) {
         return raw;
      } else if (VoxySeasonRemeshScheduler.isHandoffUnsafe(section)) {
         return raw;
      } else if (section.lvl >= 0 && section.lvl <= 2 && !(snapshot.snowCover() <= 0.005F)) {
         long[] projected = (long[])raw.clone();
         Mapper mapper = this.world.getMapper();
         Int2ByteOpenHashMap categories = new Int2ByteOpenHashMap(64);
         categories.defaultReturnValue((byte)-1);
         int scale = 1 << section.lvl;
         int half = scale >> 1;
         long seed = snapshot.visualSeed();

         for (int z = 0; z < 32; z++) {
            for (int x = 0; x < 32; x++) {
               int wx = ((section.x << 5) + x << section.lvl) + half;
               int wz = ((section.z << 5) + z << section.lvl) + half;
               double coverageNoise = OrganicSnowField.coverageNoise(wx, wz, seed);
               if (OrganicSnowField.wantsSnow(snapshot.snowCover(), coverageNoise)) {
                  if (section.lvl == 0) {
                     projectFineColumn(projected, mapper, categories, snapshot, x, z, wx, wz, coverageNoise, seed);
                  } else {
                     projectCoarseColumn(projected, mapper, categories, snapshot, section.lvl, x, z, wx, wz, coverageNoise, seed);
                  }
               }
            }
         }

         return projected;
      } else {
         return raw;
      }
   }

   @Unique
   private static void projectFineColumn(
      long[] projected, Mapper mapper, Int2ByteOpenHashMap categories, SeasonSnapshot snapshot, int x, int z, int wx, int wz, double coverageNoise, long seed
   ) {
      int topY = findTopNonAir(projected, x, z);
      if (topY >= 0) {
         int scanY = topY;
         boolean hadFlora = false;

         while (scanY >= 0) {
            long voxel = projected[WorldSection.getIndex(x, scanY, z)];
            if (Mapper.isAir(voxel)) {
               scanY--;
            } else {
               if (!isSeasonalFlora(mapper, categories, voxel)) {
                  break;
               }

               hadFlora = true;
               scanY--;
            }
         }

         if (scanY >= 0 && scanY < 31) {
            long ground = projected[WorldSection.getIndex(x, scanY, z)];
            if (isSnowGround(mapper, categories, ground)) {
               int snowY = scanY + 1;
               int snowIndex = WorldSection.getIndex(x, snowY, z);
               long occupant = projected[snowIndex];
               if (Mapper.isAir(occupant) || isSeasonalFlora(mapper, categories, occupant)) {
                  int worldLayers = snowLayers(snapshot.snowCover(), coverageNoise, wx, wz, seed);
                  projected[snowIndex] = snowVoxel(mapper, occupant, ground, worldLayers);
                  if (hadFlora) {
                     for (int y = snowY + 1; y <= topY && y < 32; y++) {
                        int idx = WorldSection.getIndex(x, y, z);
                        long voxel = projected[idx];
                        if (!Mapper.isAir(voxel) && isSeasonalFlora(mapper, categories, voxel)) {
                           projected[idx] = Mapper.airWithLight(Mapper.getLightId(voxel));
                        }
                     }
                  }
               }
            }
         }
      }
   }

   @Unique
   private static void projectCoarseColumn(
      long[] projected,
      Mapper mapper,
      Int2ByteOpenHashMap categories,
      SeasonSnapshot snapshot,
      int lod,
      int x,
      int z,
      int wx,
      int wz,
      double coverageNoise,
      long seed
   ) {
      int topY = findTopNonAir(projected, x, z);
      if (topY >= 0) {
         int groundY = topY;

         int floraCount;
         for (floraCount = 0; groundY >= 0; groundY--) {
            long voxel = projected[WorldSection.getIndex(x, groundY, z)];
            if (!isSeasonalFlora(mapper, categories, voxel)) {
               break;
            }

            floraCount++;
         }

         if (groundY >= 0 && groundY < 31) {
            long ground = projected[WorldSection.getIndex(x, groundY, z)];
            if (isSnowGround(mapper, categories, ground)) {
               int snowY = groundY + 1;
               int snowIndex = WorldSection.getIndex(x, snowY, z);
               long occupant = projected[snowIndex];
               if (floraCount <= 1) {
                  if (Mapper.isAir(occupant) || isSeasonalFlora(mapper, categories, occupant)) {
                     int worldLayers = snowLayers(snapshot.snowCover(), coverageNoise, wx, wz, seed);
                     int scale = 1 << lod;
                     if (lod != 2 || worldLayers >= 3) {
                        int modelLayers = Math.max(1, Math.min(8, Math.round((float)worldLayers / scale)));
                        projected[snowIndex] = snowVoxel(mapper, occupant, ground, modelLayers);
                     }
                  }
               }
            }
         }
      }
   }

   @Unique
   private static int findTopNonAir(long[] projected, int x, int z) {
      for (int y = 30; y >= 0; y--) {
         if (!Mapper.isAir(projected[WorldSection.getIndex(x, y, z)])) {
            return y;
         }
      }

      return -1;
   }

   @Unique
   private static boolean isSeasonalFlora(Mapper mapper, Int2ByteOpenHashMap categories, long voxel) {
      if (Mapper.isAir(voxel)) {
         return false;
      } else {
         try {
            BlockState state = mapper.getBlockStateFromBlockId(Mapper.getBlockId(voxel));
            if (SeasonalBlockClassifier.floraKind(state) != SeasonalFloraKind.NONE) {
               return true;
            }
         } catch (Throwable var5) {
         }

         int c = category(mapper, categories, voxel);
         return c == 2 || c == 5 || c == 8 || c == 9;
      }
   }

   @Unique
   private static boolean isSnowGround(Mapper mapper, Int2ByteOpenHashMap categories, long voxel) {
      if (Mapper.isAir(voxel)) {
         return false;
      } else {
         int c = category(mapper, categories, voxel);
         return c == 4 || c == 6;
      }
   }

   @Unique
   private static long snowVoxel(Mapper mapper, long oldAtSnowPos, long ground, int layers) {
      BlockState snowState = (BlockState)Blocks.SNOW.defaultBlockState().setValue(SnowLayerBlock.LAYERS, Math.max(1, Math.min(8, layers)));
      int snowBlockId = mapper.getIdForBlockState(snowState);
      int light = Mapper.getLightId(oldAtSnowPos);
      long lightCarrier = Mapper.airWithLight(light);
      return Mapper.withBlockBiome(lightCarrier, snowBlockId, Mapper.getBiomeId(ground));
   }

   @Unique
   private static int category(Mapper mapper, Int2ByteOpenHashMap cache, long voxel) {
      int blockId = Mapper.getBlockId(voxel);
      byte cached = cache.get(blockId);
      if (cached >= 0) {
         return cached;
      } else {
         int value = 0;

         try {
            value = VoxySeasonCategories.categoryFor(mapper.getBlockStateFromBlockId(blockId));
         } catch (Throwable var8) {
         }

         cache.put(blockId, (byte)value);
         return value;
      }
   }

   @Unique
   private static int snowLayers(float cover, double coverageNoise, int x, int z, long seed) {
      float depthInsidePatch = clamp01((float)((cover - coverageNoise + 0.1) / Math.max(0.22, cover + 0.08)));
      float local = (float)hash01(x, 0, z, seed, 1397641047);
      float depth = clamp01(cover * 0.38F + depthInsidePatch * 0.48F + local * 0.14F);
      return Math.max(1, Math.min(8, 1 + (int)Math.floor(depth * 7.0F)));
   }

   @Unique
   private static double hash01(int x, int y, int z, long seed, int salt) {
      long h = seed ^ Integer.toUnsignedLong(salt);
      h ^= x * -7046029254386353131L;
      h ^= y * -4417276706812531889L;
      h ^= z * 1609587929392839161L;
      h ^= h >>> 30;
      h *= -4658895280553007687L;
      h ^= h >>> 27;
      h *= -7723592293110705685L;
      h ^= h >>> 31;
      return (h >>> 11) * 1.110223E-16F;
   }

   @Unique
   private static float clamp01(float value) {
      return Math.max(0.0F, Math.min(1.0F, value));
   }
}
