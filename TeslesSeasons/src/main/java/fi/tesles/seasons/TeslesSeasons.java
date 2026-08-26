package fi.tesles.seasons;

import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.block.TeslesSeasonBlocks;
import fi.tesles.seasons.command.SeasonCommands;
import fi.tesles.seasons.compat.DynamicTreesCompat;
import fi.tesles.seasons.compat.VoxyServerBackfillBridge;
import fi.tesles.seasons.debug.SeasonDebugController;
import fi.tesles.seasons.network.DiagnosticCapturePayload;
import fi.tesles.seasons.network.SeasonSyncPayload;
import fi.tesles.seasons.network.WeatherSyncPayload;
import fi.tesles.seasons.weather.SeasonWeatherController;
import fi.tesles.seasons.weather.WeatherSnapshot;
import fi.tesles.seasons.world.SeasonalWorldData;
import fi.tesles.seasons.world.effect.WaterFreezeEffect;
import fi.tesles.seasons.world.effect.SeasonalWorldEffects;
import fi.tesles.seasons.world.SeasonalWorldReconciler;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerChunkEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerChunkEvents.Load;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents.ServerStarted;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents.ServerStopped;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents.EndTick;
import net.fabricmc.fabric.api.networking.v1.PayloadTypeRegistry;
import net.fabricmc.fabric.api.networking.v1.ServerPlayConnectionEvents;
import net.fabricmc.fabric.api.networking.v1.ServerPlayNetworking;
import net.fabricmc.fabric.api.networking.v1.ServerPlayConnectionEvents.Join;
import net.minecraft.resources.Identifier;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerPlayer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class TeslesSeasons implements ModInitializer {
   public static final String MOD_ID = "teslesseasons";
   public static final Logger LOGGER = LoggerFactory.getLogger("teslesseasons");
   public static TeslesSeasonsConfig CONFIG;
   private static long serverTicks;
   private static SeasonSnapshot lastBroadcastSnapshot;

   /**
    * Installs the world effects that ship with the mod.
    *
    * <p>This is the whole of what adding a seasonal world behaviour costs. An effect is a class
    * and a line here; the reconciler, the season modules and the Voxy path need no knowledge of it.
    */
   private static void registerBuiltInWorldEffects() {
      if (CONFIG != null && CONFIG.seasonalWaterFreezing) {
         SeasonalWorldEffects.register(new WaterFreezeEffect());
      }
   }

   public void onInitialize() {
      CONFIG = TeslesSeasonsConfig.load();
      TeslesSeasonBlocks.init();
      SeasonalWorldData.init();
      registerBuiltInWorldEffects();
      SeasonEngine.refresh(System.currentTimeMillis());
      SeasonCommands.register();
      PayloadTypeRegistry.clientboundPlay().register(SeasonSyncPayload.TYPE, SeasonSyncPayload.CODEC);
      PayloadTypeRegistry.clientboundPlay().register(WeatherSyncPayload.TYPE, WeatherSyncPayload.CODEC);
      PayloadTypeRegistry.clientboundPlay().register(DiagnosticCapturePayload.TYPE, DiagnosticCapturePayload.CODEC);
      ServerPlayConnectionEvents.JOIN.register((Join)(listener, sender, server) -> {
         SeasonSnapshot snapshot = SeasonEngine.refresh(System.currentTimeMillis());
         sender.sendPacket(SeasonSyncPayload.from(snapshot));
         sender.sendPacket(WeatherSyncPayload.from(SeasonWeatherController.snapshot()));
         VoxyServerBackfillBridge.onPlayerJoin(listener.getPlayer());
      });
      ServerChunkEvents.CHUNK_LOAD.register((Load)(level, chunk, generated) -> SeasonalWorldReconciler.onChunkLoad(level, chunk));
      ServerChunkEvents.CHUNK_UNLOAD.register(SeasonalWorldReconciler::onChunkUnload);
      ServerLifecycleEvents.SERVER_STARTED
         .register(
            (ServerStarted)server -> {
               serverTicks = 0L;
               VoxyServerBackfillBridge.onServerStarted(server);
               lastBroadcastSnapshot = SeasonEngine.refresh(System.currentTimeMillis());
               SeasonWeatherController.reset();
               SeasonWeatherController.tick(server, serverTicks, System.currentTimeMillis(), lastBroadcastSnapshot);
               DynamicTreesCompat.installIfPresent();
               LOGGER.info(
                  "Real-calendar seasons active: zone={}, {} incoming days + {} outgoing days; deterministic loaded-chunk reconciliation enabled.",
                  new Object[]{CONFIG.timeZone, CONFIG.incomingTransitionDays, CONFIG.outgoingTransitionDays}
               );
               LOGGER.info("Season testing: /teslesseasons timelapse <seconds> | /teslesseasons status | /teslesseasons debug ...");
            }
         );
      ServerLifecycleEvents.SERVER_STOPPED.register((ServerStopped)server -> {
         SeasonalWorldReconciler.clear();
         SeasonDebugController.clear();
         SeasonWeatherController.reset();
         VoxyServerBackfillBridge.clear();
         lastBroadcastSnapshot = null;
      });
      ServerTickEvents.END_SERVER_TICK.register((EndTick)server -> {
         ServerDiagnosticSampler.tick(server);
         serverTicks++;
         VoxyServerBackfillBridge.tick(server);
         long now = System.currentTimeMillis();
         if (SeasonDebugController.hasAnimatedOverride() && serverTicks % 5L == 0L) {
            SeasonSnapshot snapshot = SeasonEngine.refresh(now);
            broadcastSeason(server, snapshot, false);
            if (SeasonDebugController.transitionComplete(now)) {
               SeasonDebugController.finishTransition();
               SeasonSnapshot finalSnapshot = SeasonEngine.refresh(now);
               broadcastSeason(server, finalSnapshot, true);
            }
         }

         SeasonSnapshot current = SeasonEngine.current();
         if (SeasonWeatherController.tick(server, serverTicks, now, current)) {
            broadcastWeather(server, SeasonWeatherController.snapshot());
         }

         SeasonalWorldReconciler.tick(server, current);
         if (!SeasonDebugController.isActive()) {
            long refreshTicks = Math.max(100L, CONFIG.calendarRefreshSeconds * 20L);
            if (serverTicks % refreshTicks == 0L) {
               SeasonSnapshot snapshot = SeasonEngine.refresh(now);
               broadcastSeason(server, snapshot, false);
            }
         }
      });
   }

   public static void broadcastSeason(MinecraftServer server, SeasonSnapshot snapshot, boolean force) {
      if (force || !snapshot.equals(lastBroadcastSnapshot)) {
         lastBroadcastSnapshot = snapshot;
         SeasonSyncPayload payload = SeasonSyncPayload.from(snapshot);

         for (ServerPlayer player : server.getPlayerList().getPlayers()) {
            ServerPlayNetworking.send(player, payload);
         }
      }
   }

   public static void broadcastWeather(MinecraftServer server, WeatherSnapshot snapshot) {
      WeatherSyncPayload payload = WeatherSyncPayload.from(snapshot);

      for (ServerPlayer player : server.getPlayerList().getPlayers()) {
         ServerPlayNetworking.send(player, payload);
      }
   }

   public static Identifier id(String path) {
      return Identifier.fromNamespaceAndPath("teslesseasons", path);
   }
}
