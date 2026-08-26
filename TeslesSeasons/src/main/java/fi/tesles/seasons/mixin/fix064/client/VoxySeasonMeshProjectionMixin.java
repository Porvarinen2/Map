package fi.tesles.seasons.mixin.fix064.client;

import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.render.SeasonalCategory;
import fi.tesles.seasons.client.voxy.VoxySeasonCategories;
import fi.tesles.seasons.fix064.client.VoxySeasonRemeshScheduler;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.world.SeasonalBlockClassifier;
import fi.tesles.seasons.world.SeasonalFloraKind;
import fi.tesles.seasons.world.system.LeafSystem;
import fi.tesles.seasons.world.system.SnowSystem;
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

/**
 * Projects the current season onto Voxy LOD geometry at mesh-build time.
 *
 * <p>This is the mechanism that makes distant terrain season-correct without storing any
 * season in Voxy's persistent LOD database. Voxy keeps neutral geometry; this mixin takes a
 * copy of the raw section data on its way into the mesher and applies the current
 * {@link SeasonFrame} to it. A section rebuilt tomorrow gets tomorrow's season, and a section
 * ingested last winter has no winter baked into it.
 *
 * <h2>Parity</h2>
 * Snow selection and depth come from {@link SnowSystem#targetLayers}, the exact function the
 * server uses to place physical snow. This is deliberate and load-bearing: the previous
 * implementation used a separate multi-octave "organic" noise field here while the physical
 * world used the flat coordinate hash, so near terrain and LOD terrain disagreed about which
 * columns were snowy at every partial coverage. Do not substitute a different field here to
 * make the LOD look prettier - fix the shared field instead.
 *
 * <p>Only LOD levels 0-2 are projected. Beyond that a voxel spans enough blocks that
 * per-column snow is meaningless, and the shader's snow tint carries the appearance.
 */
@Pseudo
@Mixin(
   targets = {"me.cortex.voxy.client.core.rendering.building.RenderDataFactory"},
   remap = false
)
public abstract class VoxySeasonMeshProjectionMixin {
   @Shadow
   @Final
   private WorldEngine world;

   /** Section currently being meshed, handed from generateMesh() down to prepareSectionData(). */
   @Unique
   private static final ThreadLocal<WorldSection> TESLES_SECTION = new ThreadLocal<>();

   @Unique
   private static final int TESLES_MAX_PROJECTED_LOD = 2;

   /** Distance between two vertically adjacent voxels in WorldSection's packed index. */
   @Unique
   private static final int Y_STRIDE = 1 << 10;

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
      SeasonFrame frame = ClientSeasonState.frame();
      if (section == null || frame == null || raw == null || raw.length != 32768) {
         return raw;
      }

      // Stamp the section with the geometry key it is being meshed against, whatever happens
      // below. Sections that legitimately need no seasonal geometry must still count as
      // current, or the cache-bypass mixin would reject them forever and they would remesh
      // every frame.
      VoxySeasonRemeshScheduler.markProjected(section.key, frame.geometryKey());

      if (section.lvl < 0) {
         return raw;
      }

      // Sections inside the vanilla render distance are drawn from real blocks, so season must
      // not be *added* to their LOD copy or the handoff seam shows it twice. Stale snow is
      // still stripped from them: it would otherwise peek through at the seam.
      boolean mayAddSnow = section.lvl <= TESLES_MAX_PROJECTED_LOD
         && !VoxySeasonRemeshScheduler.isHandoffUnsafe(section);

      long[] projected = null;
      Mapper mapper = this.world.getMapper();
      Int2ByteOpenHashMap categories = new Int2ByteOpenHashMap(64);
      categories.defaultReturnValue((byte) -1);
      Int2ByteOpenHashMap snowFlags = new Int2ByteOpenHashMap(32);
      snowFlags.defaultReturnValue((byte) -1);
      Int2ByteOpenHashMap groundFlags = new Int2ByteOpenHashMap(64);
      groundFlags.defaultReturnValue((byte) -1);
      Int2ByteOpenHashMap leafFlags = new Int2ByteOpenHashMap(32);
      leafFlags.defaultReturnValue((byte) -1);

      int half = (1 << section.lvl) >> 1;
      long seed = ClientSeasonState.get().visualSeed();

      // Leaves come off first, before a single flake is placed. Snow is put on the surface of a
      // column, so a canopy that is about to be deleted must not be allowed to act as that
      // surface: doing snow first left a lid of snow hanging in the air exactly where the winter
      // canopy used to be, and that floating lid went on shading the ground beneath it. Removing
      // the canopy first means the column the snow pass sees is the column that will be drawn.
      if (frame.leafRetention() < 0.9999F) {
         projected = stripAbsentLeaves(projected, raw, section, mapper, categories, seed);
      }

      for (int z = 0; z < 32; z++) {
         for (int x = 0; x < 32; x++) {
            // Representative world column for this voxel. At LOD 0 this is the exact block
            // column the server evaluates, giving coordinate-for-coordinate parity.
            int wx = (((section.x << 5) + x) << section.lvl) + half;
            int wz = (((section.z << 5) + z) << section.lvl) + half;
            int worldLayers = SnowSystem.targetLayers(frame, wx, wz, seed);

            // Clear the column of seasonal snow before deciding anything, at every height and
            // every LOD level.
            //
            // Every height, because checking only the topmost voxel left snow stranded wherever
            // something stood above it - under a trunk, or under a canopy at coarse LOD where tree
            // and ground merge into one column. That is the snow that stayed under distant trees
            // after the rest of the world had thawed.
            //
            // Before deciding, because a column that still holds last winter's snow at its surface
            // has no ground for this winter's snow to be placed on, so its depth could never be
            // corrected either.
            for (int y = 31; y >= 0; y--) {
               int index = WorldSection.getIndex(x, y, z);
               long voxel = (projected == null ? raw : projected)[index];
               if (Mapper.isAir(voxel) || !isSeasonalSnowVoxel(mapper, snowFlags, voxel)) {
                  continue;
               }
               if (projected == null) {
                  projected = raw.clone();
               }
               stripSnowVoxel(projected, section.lvl, index);
            }

            if (!mayAddSnow || worldLayers <= 0) {
               continue;
            }

            if (projected == null) {
               projected = raw.clone();
            }
            if (section.lvl == 0) {
               projectFineColumn(projected, mapper, categories, groundFlags, leafFlags, x, z, worldLayers);
            } else {
               projectCoarseColumn(projected, mapper, categories, groundFlags, leafFlags, section.lvl, x, z, worldLayers);
            }
         }
      }

      return projected == null ? raw : projected;
   }

   /**
    * Removes deciduous leaf voxels the current frame says are gone.
    *
    * <p>Skipped entirely while leaves are whole, so this costs nothing outside the seasons that
    * actually drop them. Evergreens are classified separately and keep their needles.
    */
   @Unique
   private static long[] stripAbsentLeaves(long[] projected, long[] raw, WorldSection section,
                                           Mapper mapper, Int2ByteOpenHashMap categories, long seed) {
      SeasonFrame frame = ClientSeasonState.frame();
      long[] data = projected == null ? raw : projected;
      int half = (1 << section.lvl) >> 1;
      int baseX = (section.x << 5) << section.lvl;
      int baseY = (section.y << 5) << section.lvl;
      int baseZ = (section.z << 5) << section.lvl;

      for (int y = 0; y < 32; y++) {
         for (int z = 0; z < 32; z++) {
            for (int x = 0; x < 32; x++) {
               int index = WorldSection.getIndex(x, y, z);
               long voxel = data[index];
               if (Mapper.isAir(voxel) || !isDeciduousLeafCategory(category(mapper, categories, voxel))) {
                  continue;
               }

               int wx = baseX + (x << section.lvl) + half;
               int wy = baseY + (y << section.lvl) + half;
               int wz = baseZ + (z << section.lvl) + half;
               if (LeafSystem.shouldExist(wx, wy, wz, frame, seed)) {
                  continue;
               }

               if (projected == null) {
                  projected = raw.clone();
                  data = projected;
               }
               data[index] = Mapper.airWithLight(Mapper.getLightId(voxel));
            }
         }
      }
      return projected;
   }

   /**
    * Whether a Voxy category is deciduous foliage.
    *
    * <p>VoxySeasonCategories splits deciduous leaves into per-species ids so autumn colour can
    * differ by tree, so matching only the generic id would miss birch, oak, dark oak, maple and
    * aspen - that is to say, nearly every deciduous tree in the world.
    */
   @Unique
   private static boolean isDeciduousLeafCategory(int category) {
      return category == SeasonalCategory.DECIDUOUS_LEAVES.voxyId() || (category >= 11 && category <= 15);
   }

   /**
    * Index of the column's surface voxel, or -1.
    *
    * <p>Air and foliage are skipped, which is what makes this the surface rather than merely the
    * topmost occupied voxel. The server finds the same position with the
    * {@code MOTION_BLOCKING_NO_LEAVES} heightmap; a search that stopped at the first non-air
    * voxel found the canopy in every forested column and treated it as ground.
    */
   @Unique
   private static int topSurfaceIndex(long[] data, int x, int z, Mapper mapper, Int2ByteOpenHashMap leafFlags) {
      for (int y = 31; y >= 0; y--) {
         int index = WorldSection.getIndex(x, y, z);
         long voxel = data[index];
         if (Mapper.isAir(voxel) || isLeafVoxel(mapper, leafFlags, voxel)) {
            continue;
         }
         return index;
      }
      return -1;
   }

   /** Highest y that is neither air nor foliage, or -1. */
   @Unique
   private static int findTopSurfaceY(long[] data, int x, int z, Mapper mapper, Int2ByteOpenHashMap leafFlags) {
      for (int y = 30; y >= 0; y--) {
         long voxel = data[WorldSection.getIndex(x, y, z)];
         if (Mapper.isAir(voxel) || isLeafVoxel(mapper, leafFlags, voxel)) {
            continue;
         }
         return y;
      }
      return -1;
   }

   /** Any foliage, evergreen included - the set the surface search must look straight through. */
   @Unique
   private static boolean isLeafVoxel(Mapper mapper, Int2ByteOpenHashMap cache, long voxel) {
      if (Mapper.isAir(voxel)) {
         return false;
      }
      int blockId = Mapper.getBlockId(voxel);
      byte cached = cache.get(blockId);
      if (cached >= 0) {
         return cached != 0;
      }

      boolean leaf = false;
      try {
         leaf = SeasonalBlockClassifier.isAnyLeaf(mapper.getBlockStateFromBlockId(blockId));
      } catch (Throwable ignored) {
         // Unmapped id: treat as not-foliage, which is the conservative answer here.
      }
      cache.put(blockId, (byte) (leaf ? 1 : 0));
      return leaf;
   }

   /**
    * Removes a snow voxel the current season does not want.
    *
    * <p>At LOD 0 a snow layer sits on top of the ground, so it simply becomes air. At coarser
    * levels the voxel may itself be standing in for the terrain surface, and turning it to air
    * would punch a hole in the landscape; there it takes on the material of the voxel below so
    * the surface keeps its height and gains the right colour.
    */
   @Unique
   private static void stripSnowVoxel(long[] projected, int lvl, int index) {
      long voxel = projected[index];
      int light = Mapper.getLightId(voxel);
      if (lvl == 0) {
         projected[index] = Mapper.airWithLight(light);
         return;
      }

      // WorldSection packs a voxel index as (y << 10) | (z << 5) | x, so the voxel directly
      // below is exactly one Y stride lower. An index below that stride is already at y == 0.
      //
      // With no voxel below to take a material from - the bottom row of the section, or open air
      // underneath - the voxel is left exactly as it is. Turning it to air instead punched a hole
      // straight through the landscape, and because the bottom row of every section qualifies,
      // those holes appeared in bands: distant ground you could see the sky through. A snow voxel
      // that outstays its season is a far smaller fault than a missing one.
      int below = index - Y_STRIDE;
      if (below < 0) {
         return;
      }

      long substitute = projected[below];
      if (Mapper.isAir(substitute)) {
         return;
      }

      projected[index] = Mapper.withBlockBiome(Mapper.airWithLight(light),
         Mapper.getBlockId(substitute), Mapper.getBiomeId(substitute));
   }

   /** Whether this voxel is snow the season system is responsible for. */
   @Unique
   private static boolean isSeasonalSnowVoxel(Mapper mapper, Int2ByteOpenHashMap cache, long voxel) {
      if (Mapper.isAir(voxel)) {
         return false;
      }
      int blockId = Mapper.getBlockId(voxel);
      byte cached = cache.get(blockId);
      if (cached >= 0) {
         return cached != 0;
      }

      boolean snow = false;
      try {
         BlockState state = mapper.getBlockStateFromBlockId(blockId);
         // Snow layers only. The season places layers and never a full snow block, so treating
         // snow blocks as seasonal meant deleting players' snow builds out of the distant view.
         snow = SnowSystem.isSnowLayer(state);
      } catch (Throwable ignored) {
         // Unmapped id: treat as not-snow rather than risk deleting real terrain.
      }
      cache.put(blockId, (byte) (snow ? 1 : 0));
      return snow;
   }

   /**
    * LOD 0: one voxel is one block. Walk down through seasonal flora to the ground, put the
    * snow layer directly on it, and clear the flora the snow has buried - matching what the
    * server physically did to the same column.
    */
   @Unique
   private static void projectFineColumn(long[] projected, Mapper mapper, Int2ByteOpenHashMap categories,
                                         Int2ByteOpenHashMap groundFlags, Int2ByteOpenHashMap leafFlags,
                                         int x, int z, int worldLayers) {
      int topY = findTopSurfaceY(projected, x, z, mapper, leafFlags);
      if (topY < 0) {
         return;
      }

      int scanY = topY;
      boolean hadFlora = false;
      while (scanY >= 0) {
         long voxel = projected[WorldSection.getIndex(x, scanY, z)];
         if (Mapper.isAir(voxel)) {
            scanY--;
         } else if (isSeasonalFlora(mapper, categories, voxel)) {
            hadFlora = true;
            scanY--;
         } else {
            break;
         }
      }

      if (scanY < 0 || scanY >= 31) {
         return;
      }

      long ground = projected[WorldSection.getIndex(x, scanY, z)];
      if (!isSnowGround(mapper, categories, groundFlags, ground)) {
         return;
      }

      int snowY = scanY + 1;
      int snowIndex = WorldSection.getIndex(x, snowY, z);
      long occupant = projected[snowIndex];
      if (!Mapper.isAir(occupant) && !isSeasonalFlora(mapper, categories, occupant)) {
         return;
      }

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

   /**
    * LOD 1-2: one voxel spans 2 or 4 blocks, so the block-accurate layer count is scaled down
    * to the voxel's own resolution. At LOD 2 a thin dusting is dropped entirely rather than
    * rendered as a full voxel of snow.
    */
   @Unique
   private static void projectCoarseColumn(long[] projected, Mapper mapper, Int2ByteOpenHashMap categories,
                                           Int2ByteOpenHashMap groundFlags, Int2ByteOpenHashMap leafFlags,
                                           int lod, int x, int z, int worldLayers) {
      int topY = findTopSurfaceY(projected, x, z, mapper, leafFlags);
      if (topY < 0) {
         return;
      }

      int groundY = topY;
      int floraCount = 0;
      while (groundY >= 0) {
         long voxel = projected[WorldSection.getIndex(x, groundY, z)];
         if (!isSeasonalFlora(mapper, categories, voxel)) {
            break;
         }
         floraCount++;
         groundY--;
      }

      if (groundY < 0 || groundY >= 31 || floraCount > 1) {
         return;
      }

      long ground = projected[WorldSection.getIndex(x, groundY, z)];
      if (!isSnowGround(mapper, categories, groundFlags, ground)) {
         return;
      }

      int snowIndex = WorldSection.getIndex(x, groundY + 1, z);
      long occupant = projected[snowIndex];
      if (!Mapper.isAir(occupant) && !isSeasonalFlora(mapper, categories, occupant)) {
         return;
      }

      int scale = 1 << lod;
      if (lod == TESLES_MAX_PROJECTED_LOD && worldLayers < 3) {
         return;
      }

      int modelLayers = Math.max(1, Math.min(8, Math.round((float) worldLayers / scale)));
      projected[snowIndex] = snowVoxel(mapper, occupant, ground, modelLayers);
   }

   @Unique
   private static boolean isSeasonalFlora(Mapper mapper, Int2ByteOpenHashMap categories, long voxel) {
      if (Mapper.isAir(voxel)) {
         return false;
      }

      try {
         BlockState state = mapper.getBlockStateFromBlockId(Mapper.getBlockId(voxel));
         if (SeasonalBlockClassifier.floraKind(state) != SeasonalFloraKind.NONE) {
            return true;
         }
      } catch (Throwable ignored) {
         // Unmapped block id: fall through to the cached visual category.
      }

      int c = category(mapper, categories, voxel);
      return c == SeasonalCategory.GROUND_VEGETATION.voxyId()
         || c == SeasonalCategory.FLOWER.voxyId()
         || c == SeasonalCategory.MUSHROOM.voxyId()
         || c == SeasonalCategory.SNOW_REPLACEABLE_DECOR.voxyId();
   }

   /**
    * Whether snow may rest on this voxel.
    *
    * <p>Snow settles on whatever solid surface is there - stone, gravel, a roof, a fallen log -
    * exactly as the server's SnowLayerBlock placement does. Restricting it to two hand-picked
    * ground categories left every other surface bare, which at LOD range reads as a grey and
    * green speckle through the snowfield rather than as snow.
    *
    * <p>But "whatever is there" is not "anything at all". The server's placement is gated by
    * {@code SnowLayerBlock.canSurvive}, and a blacklist of a few seasonal categories was not that
    * gate: it admitted water, so distant rivers and lakes grew a crust of snow the physical world
    * never had, and it admitted foliage, so canopies were snowed over. This mirrors canSurvive
    * with the information a voxel carries - no Level is available at mesh-build time.
    */
   @Unique
   private static boolean isSnowGround(Mapper mapper, Int2ByteOpenHashMap categories,
                                       Int2ByteOpenHashMap groundFlags, long voxel) {
      if (Mapper.isAir(voxel)) {
         return false;
      }

      int c = category(mapper, categories, voxel);
      if (c == SeasonalCategory.SEASONAL_SNOW.voxyId()
         || c == SeasonalCategory.GROUND_VEGETATION.voxyId()
         || c == SeasonalCategory.FLOWER.voxyId()
         || c == SeasonalCategory.MUSHROOM.voxyId()
         || c == SeasonalCategory.SNOW_REPLACEABLE_DECOR.voxyId()) {
         return false;
      }

      int blockId = Mapper.getBlockId(voxel);
      byte cached = groundFlags.get(blockId);
      if (cached >= 0) {
         return cached != 0;
      }

      boolean ground = false;
      try {
         BlockState state = mapper.getBlockStateFromBlockId(blockId);
         ground = SnowSystem.canRestOn(state);
      } catch (Throwable ignored) {
         // Unmapped id: refuse rather than invent snow on something unknown.
      }
      groundFlags.put(blockId, (byte) (ground ? 1 : 0));
      return ground;
   }


   @Unique
   private static long snowVoxel(Mapper mapper, long oldAtSnowPos, long ground, int layers) {
      BlockState snowState = Blocks.SNOW.defaultBlockState()
         .setValue(SnowLayerBlock.LAYERS, Math.max(1, Math.min(8, layers)));
      int snowBlockId = mapper.getIdForBlockState(snowState);
      long lightCarrier = Mapper.airWithLight(Mapper.getLightId(oldAtSnowPos));
      return Mapper.withBlockBiome(lightCarrier, snowBlockId, Mapper.getBiomeId(ground));
   }

   @Unique
   private static int category(Mapper mapper, Int2ByteOpenHashMap cache, long voxel) {
      int blockId = Mapper.getBlockId(voxel);
      byte cached = cache.get(blockId);
      if (cached >= 0) {
         return cached;
      }

      int value = 0;
      try {
         value = VoxySeasonCategories.categoryFor(mapper.getBlockStateFromBlockId(blockId));
      } catch (Throwable ignored) {
         // Leave as the neutral category; a bad id must not abort the whole mesh.
      }

      cache.put(blockId, (byte) value);
      return value;
   }
}
