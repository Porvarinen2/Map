package fi.tesles.seasons.fix070.client;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Comparator;
import java.util.stream.Stream;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.loader.api.FabricLoader;

public final class VoxyEpochV9Client implements ClientModInitializer {
   private static final String EPOCH = "v9";

   public void onInitializeClient() {
      FabricLoader loader = FabricLoader.getInstance();
      if (loader.isModLoaded("voxy")) {
         Path gameDir = loader.getGameDir();
         Path marker = gameDir.resolve("config").resolve("teslesseasons").resolve("voxy-client-neutral-v9.done");
         if (!Files.exists(marker)) {
            Path hashes = gameDir.resolve("voxyserver").resolve("hashes");

            try {
               if (loader.isModLoaded("voxyserver") && Files.exists(hashes)) {
                  try (Stream<Path> walk = Files.walk(hashes)) {
                     for (Path path : walk.sorted(Comparator.reverseOrder()).toList()) {
                        Files.deleteIfExists(path);
                     }
                  }
               }

               Files.createDirectories(marker.getParent());
               Files.writeString(marker, "TESLES neutral Voxy cache epoch v9" + System.lineSeparator());
            } catch (IOException var10) {
            }
         }
      }
   }
}
