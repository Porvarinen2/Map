package fi.tesles.seasons.client;

import fi.tesles.seasons.client.render.NearMeshRefreshQueue;
import fi.tesles.seasons.client.render.SeasonalModelLoading;
import fi.tesles.seasons.client.render.SeasonalTinting;
import fi.tesles.seasons.network.DiagnosticCapturePayload;
import fi.tesles.seasons.network.SeasonSyncPayload;
import fi.tesles.seasons.network.WeatherSyncPayload;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents.EndTick;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayNetworking;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents.Disconnect;

public final class TeslesSeasonsClient implements ClientModInitializer {
   public void onInitializeClient() {
      SeasonalTinting.register();
      SeasonalModelLoading.register();
      ClientPlayNetworking.registerGlobalReceiver(SeasonSyncPayload.TYPE, (payload, context) -> ClientSeasonState.accept(payload.decode()));
      ClientPlayNetworking.registerGlobalReceiver(WeatherSyncPayload.TYPE, (payload, context) -> ClientWeatherState.accept(payload.decode()));
      ClientPlayNetworking.registerGlobalReceiver(
         DiagnosticCapturePayload.TYPE,
         (payload, context) -> context.client().execute(() -> SeasonDiagnosticRecorder.accept(payload.decode(), context.client()))
      );
      ClientPlayConnectionEvents.DISCONNECT.register((Disconnect)(listener, client) -> {
         SeasonDiagnosticRecorder.reset(client);
         ClientSeasonState.reset();
         ClientWeatherState.reset();
         CustomWeatherEffects.reset();
      });
      ClientTickEvents.END_CLIENT_TICK.register((EndTick)client -> {
         NearMeshRefreshQueue.tick(client);
         CustomWeatherEffects.tick(client);
         SeasonDiagnosticRecorder.tick(client);
      });
   }
}
