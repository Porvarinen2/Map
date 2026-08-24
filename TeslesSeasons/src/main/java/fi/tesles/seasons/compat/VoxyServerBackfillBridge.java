package fi.tesles.seasons.compat;

import fi.tesles.seasons.TeslesSeasons;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import net.fabricmc.loader.api.FabricLoader;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.level.storage.LevelResource;

public final class VoxyServerBackfillBridge {
   private static final String MARKER_NAME = "voxyserver-existing-overworld-backfill-v3.done";
   private static final String IDLE_STATUS = "no import is running";
   private static Object voxyServer;
   private static Object coordinator;
   private static MinecraftServer server;
   private static Path marker;
   private static boolean initialized;
   private static boolean pending;
   private static boolean running;
   private static boolean completed;
   private static long ticks;
   private static String lastStatus = "not initialized";

   private VoxyServerBackfillBridge() {
   }

   public static void captureInstance(Object instance) {
      voxyServer = instance;
      lastStatus = "VoxyServer captured; waiting for server engine";
   }

   public static void onServerStarted(MinecraftServer minecraftServer) {
      server = minecraftServer;
      ticks = 0L;
      tryInitialize();
      tryAutoStart();
   }

   public static void onPlayerJoin(ServerPlayer player) {
      if (player != null) {
         if (server == null) {
            server = player.level().getServer();
         }

         tryInitialize();
         if (player.level().getServer() == server && pending && !running && !completed) {
            tryStart(player.createCommandSourceStack(), false);
         }
      }
   }

   public static void tick(MinecraftServer minecraftServer) {
      if (minecraftServer != null) {
         if (server == null) {
            server = minecraftServer;
         }

         if (minecraftServer == server) {
            ticks++;
            if (ticks % 100L == 0L) {
               if (!initialized) {
                  tryInitialize();
               }

               if (coordinator != null) {
                  if (running) {
                     String status = coordinatorStatus();
                     lastStatus = status;
                     if ("no import is running".equalsIgnoreCase(status.trim())) {
                        running = false;
                        pending = false;
                        completed = true;
                        writeMarker();
                        TeslesSeasons.LOGGER.info("TESLES VoxyServer existing-region backfill completed; cached LOD terrain can stream without client visits.");
                     }
                  } else {
                     if (pending && !completed) {
                        tryAutoStart();
                     }
                  }
               }
            }
         }
      }
   }

   private static void tryAutoStart() {
      if (server != null && coordinator != null && pending && !running && !completed) {
         tryStart(server.createCommandSourceStack(), false);
      }
   }

   public static String requestBackfill(CommandSourceStack source) {
      if (!FabricLoader.getInstance().isModLoaded("voxyserver")) {
         return "VoxyServer is not installed.";
      } else if (source == null) {
         return "No command source available.";
      } else {
         if (server == null) {
            server = source.getServer();
         }

         tryInitialize();
         if (coordinator == null) {
            return "VoxyServer import coordinator is not ready yet.";
         } else if (running) {
            return "VoxyServer backfill is already running: " + coordinatorStatus();
         } else {
            completed = false;
            pending = true;

            try {
               if (marker != null) {
                  Files.deleteIfExists(marker);
               }
            } catch (Exception var2) {
            }

            boolean accepted = tryStart(source, true);
            return accepted ? "Started VoxyServer existing-overworld backfill." : "VoxyServer did not accept the backfill yet: " + coordinatorStatus();
         }
      }
   }

   public static String status() {
      if (!FabricLoader.getInstance().isModLoaded("voxyserver")) {
         return "voxy: VoxyServer not installed";
      } else if (initialized && coordinator != null) {
         String status = running ? coordinatorStatus() : lastStatus;
         return "voxy: backfill[completed=" + completed + ",pending=" + pending + ",running=" + running + "] " + status;
      } else {
         return "voxy: " + lastStatus;
      }
   }

   public static void clear() {
      voxyServer = null;
      coordinator = null;
      server = null;
      marker = null;
      initialized = false;
      pending = false;
      running = false;
      completed = false;
      ticks = 0L;
      lastStatus = "not initialized";
   }

   private static void tryInitialize() {
      if (!initialized && voxyServer != null && server != null && TeslesSeasons.CONFIG != null) {
         try {
            Method getter = voxyServer.getClass().getMethod("getImportCoordinator");
            Object value = getter.invoke(voxyServer);
            if (value == null) {
               lastStatus = "VoxyServer engine not ready yet";
               return;
            }

            coordinator = value;
            Path root = server.getWorldPath(LevelResource.ROOT);
            marker = root.resolve("teslesseasons").resolve("voxyserver-existing-overworld-backfill-v3.done");
            Path voxyStore = root.resolve("voxyserver");
            if (Files.isRegularFile(marker) && !Files.isDirectory(voxyStore)) {
               Files.deleteIfExists(marker);
            }

            completed = Files.isRegularFile(marker);
            pending = TeslesSeasons.CONFIG.voxyServerAutoBackfillExistingRegions && !completed;
            running = false;
            initialized = true;
            lastStatus = completed ? "backfill already completed" : "ready";
            TeslesSeasons.LOGGER.info("TESLES VoxyServer backfill bridge ready (completed={}, autoPending={}).", completed, pending);
         } catch (Throwable var4) {
            lastStatus = "bridge init retry pending: " + var4.getClass().getSimpleName();
         }
      }
   }

   private static boolean tryStart(CommandSourceStack source, boolean manual) {
      if (coordinator != null && server != null && source != null && !running) {
         try {
            Method startDimension = coordinator.getClass().getMethod("startDimension", CommandSourceStack.class, ServerLevel.class);
            Object result = startDimension.invoke(coordinator, source, server.overworld());
            boolean accepted = Boolean.TRUE.equals(result);
            if (accepted) {
               running = true;
               pending = true;
               lastStatus = coordinatorStatus();
               TeslesSeasons.LOGGER.info("TESLES requested VoxyServer import of existing overworld regions{}.", manual ? " (manual retry)" : "");
            } else {
               lastStatus = coordinatorStatus();
            }

            return accepted;
         } catch (Throwable var5) {
            lastStatus = "start failed: " + var5.getClass().getSimpleName();
            TeslesSeasons.LOGGER.warn("Could not start VoxyServer existing-region backfill: {}", var5.toString());
            return false;
         }
      } else {
         return false;
      }
   }

   private static String coordinatorStatus() {
      if (coordinator == null) {
         return "coordinator unavailable";
      } else {
         try {
            Method status = coordinator.getClass().getMethod("getStatusSummary");
            Object value = status.invoke(coordinator);
            return value == null ? "unknown" : value.toString();
         } catch (Throwable var2) {
            return "status unavailable: " + var2.getClass().getSimpleName();
         }
      }
   }

   private static void writeMarker() {
      if (marker != null) {
         try {
            Files.createDirectories(marker.getParent());
            Files.writeString(marker, "VoxyServer existing overworld region backfill completed by TeslesSeasons 0.5.0.\n");
         } catch (Exception var1) {
            TeslesSeasons.LOGGER.warn("Could not write VoxyServer backfill marker {}: {}", marker, var1.toString());
         }
      }
   }
}
