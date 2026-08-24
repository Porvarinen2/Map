package fi.tesles.seasons.fix064.client;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.client.ClientSeasonState;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import me.cortex.voxy.client.core.rendering.SectionUpdateRouter;
import me.cortex.voxy.common.world.WorldEngine;
import me.cortex.voxy.common.world.WorldSection;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.client.Minecraft;

public final class VoxySeasonRemeshScheduler implements ClientModInitializer {
   private static final int STEPS = 12;
   private static final int MAX_STRUCTURAL_LOD = 2;
   private static final int HANDOFF_MARGIN_BLOCKS = 64;
   private static final int HANDOFF_RESCAN_BLOCKS = 16;
   private static final Set<Long> WATCHED = ConcurrentHashMap.newKeySet();
   private static final Set<Long> PROTECTED = ConcurrentHashMap.newKeySet();
   private static final ConcurrentLinkedQueue<Long> URGENT_NEUTRAL = new ConcurrentLinkedQueue<>();
   private static final Set<Long> URGENT_NEUTRAL_SET = ConcurrentHashMap.newKeySet();
   private static volatile SectionUpdateRouter router;
   private static volatile double playerX;
   private static volatile double playerZ;
   private static volatile int handoffRadiusBlocks = 256;
   private static volatile boolean havePlayerPosition;
   private static List<Long> pending = List.of();
   private static int pendingIndex;
   private static long latestRevision = Long.MIN_VALUE;
   private static long cycleRevision = Long.MIN_VALUE;
   private static boolean rerunRequested;
   private static double lastProtectionScanX = Double.NaN;
   private static double lastProtectionScanZ = Double.NaN;
   private static int lastProtectionRadius = -1;

   public void onInitializeClient() {
      if (FabricLoader.getInstance().isModLoaded("voxy")) {
         ClientTickEvents.END_CLIENT_TICK.register(VoxySeasonRemeshScheduler::tick);
      }
   }

   public static void watch(SectionUpdateRouter updateRouter, long position) {
      router = updateRouter;
      int lvl = WorldEngine.getLevel(position);
      if (lvl >= 0 && lvl <= 2) {
         if (WATCHED.add(position)) {
            if (isHandoffUnsafe(position)) {
               PROTECTED.add(position);
               enqueueUrgentNeutral(position);
            } else {
               rerunRequested = true;
            }
         }
      }
   }

   public static void unwatch(long position) {
      int lvl = WorldEngine.getLevel(position);
      if (lvl >= 0 && lvl <= 2) {
         WATCHED.remove(position);
         PROTECTED.remove(position);
         URGENT_NEUTRAL_SET.remove(position);
      }
   }

   public static boolean isHandoffUnsafe(WorldSection section) {
      return section != null && isHandoffUnsafe(section.key);
   }

   public static boolean isHandoffUnsafe(long position) {
      if (!havePlayerPosition) {
         return false;
      } else {
         int lvl = WorldEngine.getLevel(position);
         int scale = 1 << Math.max(0, lvl);
         double cx = (((long)WorldEngine.getX(position) << 5) + 16.0) * scale;
         double cz = (((long)WorldEngine.getZ(position) << 5) + 16.0) * scale;
         double dx = cx - playerX;
         double dz = cz - playerZ;
         double radius = handoffRadiusBlocks + 16.0 * scale;
         return dx * dx + dz * dz <= radius * radius;
      }
   }

   private static void tick(Minecraft client) {
      SectionUpdateRouter currentRouter = router;
      if (currentRouter != null) {
         updateHandoffSnapshot(client);
         if (havePlayerPosition && protectionRescanNeeded()) {
            updateProtectionBand();
         }

         int neutralBudget = 8;

         while (neutralBudget-- > 0) {
            Long position = URGENT_NEUTRAL.poll();
            if (position == null) {
               break;
            }

            URGENT_NEUTRAL_SET.remove(position);
            if (WATCHED.contains(position) && isHandoffUnsafe(position)) {
               currentRouter.triggerRemesh(position);
            }
         }

         SeasonSnapshot snapshot = ClientSeasonState.get();
         if (snapshot != null) {
            long revision = revision(snapshot);
            if (revision != latestRevision) {
               latestRevision = revision;
               rerunRequested = true;
            }

            if (pendingIndex >= pending.size()) {
               if (!rerunRequested) {
                  return;
               }

               rerunRequested = false;
               beginPass(snapshot, latestRevision);
            }

            boolean endpoint = snapshot.snowCover() <= 0.005F || snapshot.snowCover() >= 0.995F;
            int seasonalBudget = endpoint ? 6 : 1;

            while (seasonalBudget-- > 0 && pendingIndex < pending.size()) {
               long positionx = pending.get(pendingIndex++);
               int lvl = WorldEngine.getLevel(positionx);
               if (lvl >= 0 && lvl <= 2 && WATCHED.contains(positionx)) {
                  if (isHandoffUnsafe(positionx)) {
                     if (PROTECTED.add(positionx)) {
                        enqueueUrgentNeutral(positionx);
                     }
                  } else {
                     currentRouter.triggerRemesh(positionx);
                  }
               }
            }

            if (pendingIndex >= pending.size() && latestRevision != cycleRevision) {
               rerunRequested = true;
            }
         }
      }
   }

   private static void updateHandoffSnapshot(Minecraft client) {
      if (client != null && client.player != null) {
         playerX = client.player.getX();
         playerZ = client.player.getZ();
         int vanillaChunks = Math.max(3, (Integer)client.options.renderDistance().get());
         handoffRadiusBlocks = vanillaChunks * 16 + 64;
         havePlayerPosition = true;
      } else {
         havePlayerPosition = false;
      }
   }

   private static boolean protectionRescanNeeded() {
      if (Double.isNaN(lastProtectionScanX) || Double.isNaN(lastProtectionScanZ)) {
         return true;
      } else if (lastProtectionRadius != handoffRadiusBlocks) {
         return true;
      } else {
         double dx = playerX - lastProtectionScanX;
         double dz = playerZ - lastProtectionScanZ;
         return dx * dx + dz * dz >= 256.0;
      }
   }

   private static void updateProtectionBand() {
      for (long position : WATCHED) {
         boolean nowProtected = isHandoffUnsafe(position);
         boolean wasProtected = PROTECTED.contains(position);
         if (nowProtected && !wasProtected) {
            PROTECTED.add(position);
            enqueueUrgentNeutral(position);
         } else if (!nowProtected && wasProtected) {
            PROTECTED.remove(position);
            rerunRequested = true;
         }
      }

      lastProtectionScanX = playerX;
      lastProtectionScanZ = playerZ;
      lastProtectionRadius = handoffRadiusBlocks;
   }

   private static void enqueueUrgentNeutral(long position) {
      if (URGENT_NEUTRAL_SET.add(position)) {
         URGENT_NEUTRAL.add(position);
      }
   }

   private static void beginPass(SeasonSnapshot snapshot, long revision) {
      ArrayList<Long> shuffled = new ArrayList<>(WATCHED);
      Collections.shuffle(shuffled, new Random(snapshot.visualSeed() ^ revision * -7046029254386353131L));
      pending = shuffled;
      pendingIndex = 0;
      cycleRevision = revision;
   }

   private static long revision(SeasonSnapshot s) {
      return quantize(s.snowCover());
   }

   private static int quantize(float value) {
      float v = Math.max(0.0F, Math.min(1.0F, value));
      return Math.max(0, Math.min(12, Math.round(v * 12.0F)));
   }
}
