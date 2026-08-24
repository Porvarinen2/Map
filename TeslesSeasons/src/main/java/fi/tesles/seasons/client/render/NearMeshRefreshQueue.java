package fi.tesles.seasons.client.render;

import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.client.ClientSeasonState;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.chunk.status.ChunkStatus;

public final class NearMeshRefreshQueue {
   private static final int DEBUG_BUCKET_OFFSET = 1000000;
   private static final LinkedHashSet<Long> CHUNKS = new LinkedHashSet<>();

   private NearMeshRefreshQueue() {
   }

   public static void queueAroundPlayer(Minecraft client) {
      if (TeslesSeasons.CONFIG.nearSeasonalTinting && client.level != null && client.player != null) {
         int radius = TeslesSeasons.CONFIG.nearRefreshRadiusChunks;
         int centerX = client.player.getBlockX() >> 4;
         int centerZ = client.player.getBlockZ() >> 4;
         CHUNKS.clear();
         List<NearMeshRefreshQueue.ChunkCandidate> candidates = new ArrayList<>();

         for (int dz = -radius; dz <= radius; dz++) {
            for (int dx = -radius; dx <= radius; dx++) {
               int distanceSq = dx * dx + dz * dz;
               if (distanceSq <= radius * radius) {
                  candidates.add(new NearMeshRefreshQueue.ChunkCandidate(pack(centerX + dx, centerZ + dz), distanceSq));
               }
            }
         }

         candidates.sort((a, b) -> Integer.compare(a.distanceSq, b.distanceSq));

         for (NearMeshRefreshQueue.ChunkCandidate candidate : candidates) {
            CHUNKS.add(candidate.packed);
         }
      }
   }

   public static void clear() {
      CHUNKS.clear();
   }

   public static void tick(Minecraft client) {
      if (!CHUNKS.isEmpty() && client.level != null && client.levelExtractor != null) {
         boolean debug = ClientSeasonState.get().visualBucket() >= 1000000;
         long budgetMicros = debug ? TeslesSeasons.CONFIG.debugNearRefreshBudgetMicros : TeslesSeasons.CONFIG.nearRefreshBudgetMicros;
         int max = debug ? TeslesSeasons.CONFIG.debugNearRefreshChunksPerTick : TeslesSeasons.CONFIG.nearRefreshChunksPerTick;
         long deadline = System.nanoTime() + budgetMicros * 1000L;

         for (int done = 0; done < max && !CHUNKS.isEmpty() && (done <= 0 || System.nanoTime() < deadline); done++) {
            long packed = CHUNKS.iterator().next();
            CHUNKS.remove(packed);
            refreshChunk(client, unpackX(packed), unpackZ(packed));
         }
      }
   }

   private static void refreshChunk(Minecraft client, int chunkX, int chunkZ) {
      ClientLevel level = client.level;
      if (level != null) {
         ChunkAccess access = level.getChunk(chunkX, chunkZ, ChunkStatus.FULL, false);
         if (access instanceof LevelChunk) {
            client.levelExtractor.setSectionRangeDirty(chunkX, level.getMinSectionY(), chunkZ, chunkX, level.getMaxSectionY() - 1, chunkZ);
         }
      }
   }

   private static long pack(int x, int z) {
      return x & 4294967295L | (long)z << 32;
   }

   private static int unpackX(long value) {
      return (int)value;
   }

   private static int unpackZ(long value) {
      return (int)(value >> 32);
   }

   private record ChunkCandidate(long packed, int distanceSq) {
   }
}
