package fi.tesles.seasons.fix061;

import fi.tesles.seasons.world.SeasonalWorldData;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.SnowyBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.LevelChunkSection;

public final class VoxyNeutralSnapshot {
   public static final AtomicLong SNAPSHOTS = new AtomicLong();
   public static final AtomicLong FAST_PATHS = new AtomicLong();
   public static final AtomicLong COPIED_SECTIONS = new AtomicLong();
   public static final AtomicLong STRIPPED_SNOW = new AtomicLong();
   public static final AtomicLong RESTORED_LEAVES = new AtomicLong();
   public static final AtomicLong RESTORED_FLORA = new AtomicLong();
   public static final AtomicLong FAILURES = new AtomicLong();

   private VoxyNeutralSnapshot() {
   }

   /**
    * What the neutraliser has actually done this session.
    *
    * <p>These counters existed from the start and were reported nowhere, which is why two rounds
    * of "distant trees stay bare" had to be reasoned about instead of read off. {@code fast} is the
    * telling one: it counts chunks handed to Voxy untouched because their ledgers were empty. A
    * bare winter chunk taking the fast path means the ledger that should have described its missing
    * canopy was not there, and the LOD it produced is winter for good.
    */
   public static String summary() {
      return "voxyNeutral[snapshots=" + SNAPSHOTS.get()
         + ",fast=" + FAST_PATHS.get()
         + ",copiedSections=" + COPIED_SECTIONS.get()
         + ",snowStripped=" + STRIPPED_SNOW.get()
         + ",leavesRestored=" + RESTORED_LEAVES.get()
         + ",floraRestored=" + RESTORED_FLORA.get()
         + ",failures=" + FAILURES.get() + "]";
   }

   public static LevelChunkSection[] copyAndNeutralize(LevelChunk chunk) {
      SNAPSHOTS.incrementAndGet();
      List<Long> ownedSnow = SeasonalWorldData.readOwnedSnow(chunk);
      List<String> removedLeaves = SeasonalWorldData.readRemovedLeaves(chunk);
      List<String> removedFlora = SeasonalWorldData.readRemovedFlora(chunk);
      LevelChunkSection[] live = chunk.getSections();
      if (ownedSnow.isEmpty() && removedLeaves.isEmpty() && removedFlora.isEmpty()) {
         FAST_PATHS.incrementAndGet();
         return live;
      } else {
         LevelChunkSection[] copy = (LevelChunkSection[])live.clone();
         boolean[] privateSection = new boolean[copy.length];

         try {
            for (long packed : ownedSnow) {
               BlockPos snowPos = SeasonalWorldData.unpackLocal(chunk, packed);
               ensurePrivate(copy, privateSection, chunk, snowPos.getY());
               ensurePrivate(copy, privateSection, chunk, snowPos.getY() - 1);
               BlockState state = get(copy, chunk, snowPos);
               if (isSeasonSnow(state)) {
                  if (set(copy, chunk, snowPos, Blocks.AIR.defaultBlockState())) {
                     STRIPPED_SNOW.incrementAndGet();
                  }

                  clearSnowyBase(copy, chunk, snowPos.below());
               }
            }

            for (String encoded : removedLeaves) {
               SeasonalWorldData.DecodedState decoded = SeasonalWorldData.decodeState(chunk, encoded);
               if (decoded != null) {
                  ensurePrivate(copy, privateSection, chunk, decoded.pos().getY());
                  if (set(copy, chunk, decoded.pos(), decoded.state())) {
                     RESTORED_LEAVES.incrementAndGet();
                  }
               }
            }

            for (String encodedx : removedFlora) {
               SeasonalWorldData.DecodedFlora decoded = SeasonalWorldData.decodeFlora(chunk, encodedx);
               if (decoded != null) {
                  ensurePrivate(copy, privateSection, chunk, decoded.pos().getY());
                  if (set(copy, chunk, decoded.pos(), decoded.state())) {
                     RESTORED_FLORA.incrementAndGet();
                  }
               }
            }
         } catch (Throwable var12) {
            FAILURES.incrementAndGet();
         }

         return copy;
      }
   }

   public static boolean isSeasonSnow(BlockState state) {
      return state != null && state.getBlock() instanceof SnowLayerBlock;
   }

   private static void ensurePrivate(LevelChunkSection[] sections, boolean[] privateSection, LevelChunk chunk, int blockY) {
      int index = (blockY >> 4) - chunk.getMinSectionY();
      if (index >= 0 && index < sections.length && !privateSection[index]) {
         LevelChunkSection section = sections[index];
         if (section != null) {
            sections[index] = section.copy();
            privateSection[index] = true;
            COPIED_SECTIONS.incrementAndGet();
         }
      }
   }

   private static void clearSnowyBase(LevelChunkSection[] sections, LevelChunk chunk, BlockPos basePos) {
      BlockState base = get(sections, chunk, basePos);
      if (base != null && base.hasProperty(SnowyBlock.SNOWY)) {
         if (Boolean.TRUE.equals(base.getValue(SnowyBlock.SNOWY))) {
            set(sections, chunk, basePos, (BlockState)base.setValue(SnowyBlock.SNOWY, false));
         }
      }
   }

   private static LevelChunkSection section(LevelChunkSection[] sections, LevelChunk chunk, int blockY) {
      int index = (blockY >> 4) - chunk.getMinSectionY();
      return index >= 0 && index < sections.length ? sections[index] : null;
   }

   private static BlockState get(LevelChunkSection[] sections, LevelChunk chunk, BlockPos pos) {
      LevelChunkSection section = section(sections, chunk, pos.getY());
      return section == null ? null : section.getBlockState(pos.getX() & 15, pos.getY() & 15, pos.getZ() & 15);
   }

   private static boolean set(LevelChunkSection[] sections, LevelChunk chunk, BlockPos pos, BlockState state) {
      LevelChunkSection section = section(sections, chunk, pos.getY());
      if (section == null) {
         return false;
      } else {
         section.setBlockState(pos.getX() & 15, pos.getY() & 15, pos.getZ() & 15, state);
         return true;
      }
   }
}
