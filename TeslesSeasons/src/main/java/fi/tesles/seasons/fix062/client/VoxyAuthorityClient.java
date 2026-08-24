package fi.tesles.seasons.fix062.client;

import com.dripps.voxyserver.client.ClientLodSettings;
import com.dripps.voxyserver.client.service.IVoxyServerIngestAccess;
import com.dripps.voxyserver.network.LODHandshakePayload;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.stream.Stream;
import me.cortex.voxy.commonImpl.VoxyCommon;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents.EndTick;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayNetworking;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents.Disconnect;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents.Join;
import net.fabricmc.loader.api.FabricLoader;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class VoxyAuthorityClient implements ClientModInitializer {
   private static final Logger LOGGER = LoggerFactory.getLogger("TeslesSeasons/VoxyAuthority");
   private static final String EPOCH = "v6";
   private static boolean preemptiveRemoteAuthority;
   private static int handshakeTicks;

   public void onInitializeClient() {
      if (FabricLoader.getInstance().isModLoaded("voxy") && FabricLoader.getInstance().isModLoaded("voxyserver")) {
         migrateClientHashEpoch();
         ClientPlayConnectionEvents.JOIN.register((Join)(handler, sender, client) -> {
            handshakeTicks = 0;
            preemptiveRemoteAuthority = ClientPlayNetworking.canSend(LODHandshakePayload.TYPE);
            if (preemptiveRemoteAuthority) {
               setRemoteAuthority(true);
               LOGGER.info("TESLES Voxy authority {}: local Voxy ingest blocked before first remote LOD packet.", "v6");
            }
         });
         ClientPlayConnectionEvents.DISCONNECT.register((Disconnect)(handler, client) -> {
            preemptiveRemoteAuthority = false;
            handshakeTicks = 0;
            setRemoteAuthority(false);
         });
         ClientTickEvents.END_CLIENT_TICK.register((EndTick)client -> {
            if (preemptiveRemoteAuthority) {
               handshakeTicks++;
               if (ClientLodSettings.isProtocolOk()) {
                  setRemoteAuthority(true);
               } else {
                  if (handshakeTicks > 100) {
                     preemptiveRemoteAuthority = false;
                     setRemoteAuthority(false);
                     LOGGER.warn("TESLES Voxy authority {}: protocol did not validate in 100 ticks; local ingest restored.", "v6");
                  }
               }
            }
         });
      }
   }

   private static void setRemoteAuthority(boolean remote) {
      try {
         if (VoxyCommon.getInstance() instanceof IVoxyServerIngestAccess access) {
            access.voxyserver$setUsingRemoteIngest(remote);
         }
      } catch (Throwable var3) {
         LOGGER.debug("Could not update VoxyServer ingest authority yet", var3);
      }
   }

   private static void migrateClientHashEpoch() {
      Path gameDir = FabricLoader.getInstance().getGameDir();
      Path marker = gameDir.resolve("config").resolve("teslesseasons").resolve("voxy-client-neutral-v6.done");
      if (!Files.exists(marker)) {
         Path hashes = gameDir.resolve("voxyserver").resolve("hashes");

         try {
            if (Files.exists(hashes)) {
               try (Stream<Path> stream = Files.walk(hashes)) {
                  for (Path path : stream.sorted(Comparator.reverseOrder()).toList()) {
                     Files.deleteIfExists(path);
                  }
               }
            }

            Files.createDirectories(marker.getParent());
            Files.writeString(
               marker,
               "TeslesSeasons Voxy client neutral-cache epoch v6"
                  + System.lineSeparator()
                  + "Old .voxy data was preserved; only the VoxyServer hash sidecar was reset once."
                  + System.lineSeparator()
            );
            LOGGER.info("TESLES Voxy client cache epoch {} prepared; VoxyServer hashes reset for authoritative refill.", "v6");
         } catch (IOException var8) {
            LOGGER.warn("TESLES could not prepare Voxy client cache epoch {}; migration will retry next launch.", "v6", var8);
         }
      }
   }
}
