package fi.tesles.seasons.client;

import com.mojang.blaze3d.platform.NativeImage;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import fi.tesles.seasons.calendar.CalendarPhase;
import fi.tesles.seasons.calendar.Season;
import fi.tesles.seasons.client.diagnostic.AerialMapRenderer;
import fi.tesles.seasons.client.diagnostic.PerformanceLog;
import fi.tesles.seasons.client.diagnostic.SeasonHud;
import fi.tesles.seasons.client.render.SeasonalCategory;
import fi.tesles.seasons.client.render.SeasonalClassifier;
import fi.tesles.seasons.client.voxy.VoxyCategoryDiagnostics;
import fi.tesles.seasons.client.voxy.VoxyShaderDiagnostics;
import fi.tesles.seasons.network.DiagnosticCapturePayload;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.weather.WeatherSnapshot;
import java.io.BufferedWriter;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.channels.SeekableByteChannel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.function.Consumer;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import net.fabricmc.loader.api.FabricLoader;
import net.fabricmc.loader.api.ModContainer;
import net.minecraft.client.Minecraft;
import net.minecraft.client.Screenshot;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.SlabBlock;
import net.minecraft.world.level.block.SnowLayerBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.levelgen.Heightmap.Types;

public final class SeasonDiagnosticRecorder {
   private static final DateTimeFormatter FILE_TIME = DateTimeFormatter.ofPattern("yyyyMMdd-HHmmss").withLocale(Locale.ROOT).withZone(ZoneId.systemDefault());
   private static SeasonDiagnosticRecorder.Session session;

   private SeasonDiagnosticRecorder() {
   }

   public static void accept(DiagnosticCapturePayload.Request request, Minecraft client) {
      if (request.isHud()) {
         String mode = request.serverSummary();
         boolean shown = "toggle".equalsIgnoreCase(mode) ? SeasonHud.toggle() : "on".equalsIgnoreCase(mode);
         if (!"toggle".equalsIgnoreCase(mode)) {
            SeasonHud.setVisible(shown);
         }
         say(client, "TESLES status panel " + (SeasonHud.isVisible() ? "on" : "off"));
         return;
      }

      if (request.isSample()) {
         // A server measurement, not a capture request: merge it into the row the client is about
         // to write and do nothing else.
         PerformanceLog.acceptServerSample(request.serverSummary());
         return;
      }

      if (client != null) {
         if (session != null) {
            finish(client, "replaced-by-new-request");
         }

         try {
            Path root = FabricLoader.getInstance().getGameDir().resolve("teslesseasons-diagnostics");
            Files.createDirectories(root);
            String stamp = FILE_TIME.format(Instant.now());
            Path dir = root.resolve("capture-" + stamp + "-" + (request.isYear() ? "year" : "single"));
            Files.createDirectories(dir);
            session = new SeasonDiagnosticRecorder.Session(dir, request, System.currentTimeMillis());
            writeText(
               dir.resolve("README.txt"),
               "TESLESSEASONS DIAGNOSTIC BUNDLE\n\nUpload this ZIP as-is when reporting a season or Voxy problem. Nothing here needs\nediting, trimming or explaining first.\n\nWHAT IS IN IT\n  NN-<phase>.png              the screen, exactly as rendered (Iris/Sodium/Voxy included)\n  NN-<phase>-map-terrain.png  plan view of what the world IS, from real block data\n  NN-<phase>-map-voxy.png     plan view of what VOXY HOLDS, per LOD section\n  NN-<phase>-state.txt        every season channel at that moment, plus Voxy counters\n  NN-<phase>-world-sample.csv the same 2401 columns every time: surface block, snow, category\n  timeline.csv                every season channel, once per second, all year\n  performance.csv             once per second: fps, frame time, heap, LOD counts,\n                              and the server's tick time, queues and ledger sizes\n  server-state.txt            the server status line\n  environment/, mods.txt, latest-log-tail.txt\n\nREADING THE MAPS\nBoth maps are north-up, 2 blocks per pixel, player at the centre cross. The bar at\nthe bottom left is 256 blocks. Thin lines are chunks, brighter lines every 512.\n\n  map-terrain swatches, left to right:\n    grass · deciduous · evergreen · snow · water · flower · mushroom · bare ground · built\n\n  map-voxy swatches, left to right:\n    GREEN  section is showing the current season\n    RED    section is still showing an OLDER season   <- this is the fault\n    BLUE   inside the vanilla render distance, real blocks are drawn there instead\n  The yellow ring is the handoff radius. Black means Voxy holds nothing there.\n\nA healthy voxy map is green with a blue disc in the middle. Red anywhere means the\nLOD kept a season it should have let go of - note where it is and roughly how far\naway, that is the useful part.\n"
            );
            writeText(dir.resolve("server-state.txt"), request.serverSummary() == null ? "" : request.serverSummary());
            writeText(dir.resolve("client-start.txt"), clientReport(client, "start"));
            writeMods(dir.resolve("mods.txt"));
            writeEnvironmentFiles(dir);
            writeTimelineHeader(dir.resolve("timeline.csv"));
            PerformanceLog.start();
            say(
               client,
               request.isYear()
                  ? "TESLES diagnostic year capture started. Keep the camera at a useful viewpoint; screenshots are automatic."
                  : "TESLES diagnostic capture started."
            );
            if (!request.isYear()) {
               requestCapture(client, "manual");
            }
         } catch (Exception var5) {
            TeslesSeasons.LOGGER.warn("Could not start TESLES diagnostic capture: {}", var5.toString());
            say(client, "TESLES diagnostic capture failed to start: " + var5.getClass().getSimpleName());
            session = null;
         }
      }
   }

   public static void tick(Minecraft client) {
      SeasonDiagnosticRecorder.Session s = session;
      if (s != null && client != null && client.level != null && client.player != null) {
         long now = System.currentTimeMillis();
         if (now - s.lastTimelineMillis >= 1000L) {
            s.lastTimelineMillis = now;
            appendTimeline(s.dir.resolve("timeline.csv"), now);
            PerformanceLog.sample(client);
         }

         if (s.request.isYear() && !s.captureBusy) {
            String label = checkpoint(ClientSeasonState.get(), s.captured);
            if (label != null) {
               requestCapture(client, label);
            }

            long expectedYearMillis = Math.max(20, s.request.durationSeconds()) * 1000L;
            if (now - s.startedMillis >= expectedYearMillis + 6000L && !s.captureBusy) {
               finish(client, "year-complete");
            } else {
               long timeout = Math.max(45000L, expectedYearMillis + 45000L);
               if (now - s.startedMillis > timeout && !s.captureBusy) {
                  finish(client, "timeout-complete");
               }
            }
         }
      }
   }

   public static void reset(Minecraft client) {
      if (session != null) {
         finish(client, "disconnect");
      }
   }

   private static String checkpoint(SeasonSnapshot snap, Set<String> captured) {
      if (snap == null) {
         return null;
      } else {
         List<String> candidates = new ArrayList<>();
         if (snap.season() == Season.SUMMER && snap.phase() == CalendarPhase.STABLE) {
            candidates.add("01-summer-stable");
         }

         if (snap.season() == Season.SUMMER && snap.phase() == CalendarPhase.OUTGOING && snap.phaseProgress() >= 0.55F) {
            candidates.add("02-summer-outgoing");
         }

         if (snap.season() == Season.AUTUMN && snap.leafRetention() <= 0.92F && snap.leafRetention() >= 0.7F) {
            candidates.add("03-autumn-early");
         }

         if (snap.season() == Season.AUTUMN && snap.leafRetention() <= 0.6F && snap.leafRetention() >= 0.35F) {
            candidates.add("04-autumn-mid");
         }

         if (snap.season() == Season.AUTUMN && snap.leafRetention() <= 0.05F && snap.snowCover() < 0.35F) {
            candidates.add("05-autumn-bare");
         }

         if (snap.season() == Season.AUTUMN && snap.snowCover() >= 0.35F) {
            candidates.add("06-first-snow");
         }

         // Winter Incoming already carries full coverage, so a coverage-only test fires on the
         // first tick of Winter - when depth is still the 1/8 handoff footprint and the capture
         // shows the thinnest snow of the whole year under the name "winter-full". Depth is what
         // separates deep winter from the handoff, so key on depth and require the Stable phase.
         if (snap.season() == Season.WINTER
            && snap.phase() == CalendarPhase.STABLE
            && ClientSeasonState.frame().snowDepth() >= 0.75F) {
            candidates.add("07-winter-full");
         }

         // The thaw is a Winter Outgoing event. SpringSector reports zero snow in all three of
         // its phases, so the old SPRING-scoped condition could never match and this checkpoint
         // was silently absent from every bundle.
         if (snap.season() == Season.WINTER
            && snap.phase() == CalendarPhase.OUTGOING
            && snap.snowCover() <= 0.8F
            && snap.snowCover() >= 0.45F) {
            candidates.add("08-winter-thaw");
         }

         // Ordered by the clock: Spring Stable opens at leaf retention 0, so the "stable" capture
         // must come before green-up or the bundle is numbered backwards against its own
         // timestamps.
         if (snap.season() == Season.SPRING && snap.phase() == CalendarPhase.STABLE && snap.snowCover() <= 0.01F) {
            candidates.add("09-spring-stable");
         }

         if (snap.season() == Season.SPRING && snap.snowCover() <= 0.3F && snap.leafRetention() >= 0.35F && snap.leafRetention() <= 0.85F) {
            candidates.add("10-spring-greenup");
         }

         for (String candidate : candidates) {
            if (!captured.contains(candidate)) {
               return candidate;
            }
         }

         return null;
      }
   }

   private static void requestCapture(Minecraft client, String label) {
      SeasonDiagnosticRecorder.Session s = session;
      if (s != null && !s.captureBusy && !s.captured.contains(label)) {
         s.captureBusy = true;
         s.captured.add(label);

         try {
            writeText(s.dir.resolve(label + "-state.txt"), clientReport(client, label));
            writeWorldSample(client, s.dir.resolve(label + "-world-sample.csv"));

            // Plan views of the same instant. A screenshot shows one direction from one place; the
            // faults that matter here are regional, and only visible from above.
            AerialMapRenderer.render(client,
               s.dir.resolve(label + "-map-terrain.png"),
               s.dir.resolve(label + "-map-voxy.png"),
               AerialMapRenderer.DEFAULT_RADIUS_BLOCKS);
            Path screenshot = s.dir.resolve(label + ".png");
            captureMinecraftScreenshot(client, screenshot, error -> {
               SeasonDiagnosticRecorder.Session current = session;
               if (current != null) {
                  if (error != null) {
                     try {
                        writeText(current.dir.resolve(label + "-screenshot-error.txt"), error);
                     } catch (Exception var5x) {
                     }
                  }

                  current.captureBusy = false;
                  if (!current.request.isYear()) {
                     finish(client, "single-complete");
                  }
               }
            });
         } catch (Exception var6) {
            Exception e = var6;
            s.captureBusy = false;

            try {
               writeText(s.dir.resolve(label + "-capture-error.txt"), e.toString());
            } catch (Exception var5) {
            }
         }
      }
   }

   private static void captureMinecraftScreenshot(Minecraft client, Path output, Consumer<String> completion) {
      try {
         Screenshot.takeScreenshot(client.gameRenderer.mainRenderTarget(), screenshot -> {
            String error = null;

            try {
               NativeImage image = screenshot;

               try {
                  Files.createDirectories(output.getParent());
                  image.writeToFile(output);
               } catch (Throwable var8) {
                  if (screenshot != null) {
                     try {
                        image.close();
                     } catch (Throwable var7) {
                        var8.addSuppressed(var7);
                     }
                  }

                  throw var8;
               }

               if (screenshot != null) {
                  screenshot.close();
               }
            } catch (Throwable var9) {
               error = var9.toString();
            }

            completion.accept(error);
         });
      } catch (Throwable var4) {
         completion.accept(var4.toString());
      }
   }

   private static String clientReport(Minecraft client, String label) {
      StringBuilder out = new StringBuilder(4096);
      SeasonSnapshot s = ClientSeasonState.get();
      WeatherSnapshot weather = ClientWeatherState.get();
      out.append("label=").append(label).append('\n');
      out.append("time=").append(Instant.now()).append('\n');
      out.append("season=").append(s.season()).append('\n');
      out.append("phase=").append(s.phase()).append('\n');
      out.append("phaseProgress=").append(s.phaseProgress()).append('\n');
      out.append("autumn=").append(s.autumnColor()).append('\n');
      out.append("leafRetention=").append(s.leafRetention()).append('\n');
      out.append("flowerRetention=").append(s.flowerRetention()).append('\n');
      out.append("mushroomRetention=").append(s.mushroomRetention()).append('\n');
      out.append("dormancy=").append(s.groundDormancy()).append('\n');
      out.append("snowCover=").append(s.snowCover()).append('\n');
      out.append("springFreshness=").append(s.springFreshness()).append('\n');
      // Channels the legacy wire snapshot does not carry. Without these a capture cannot be
      // checked against the contract at all: snow depth decides how many layers a column gets,
      // and plant/berry retention decide how much ground flora should be standing.
      SeasonFrame frame = ClientSeasonState.frame();
      out.append("snowDepth=").append(frame.snowDepth()).append('\n');
      out.append("snowDepthTarget=").append(frame.snowDepthTarget()).append('\n');
      out.append("snowCoverageTarget=").append(frame.snowCoverageTarget()).append('\n');
      out.append("plantRetention=").append(frame.plantRetention()).append('\n');
      out.append("berryRetention=").append(frame.berryRetention()).append('\n');
      out.append("groundFrost=").append(frame.groundFrost()).append('\n');
      out.append("revision=").append(frame.revision()).append('\n');
      out.append("geometryKey=").append(frame.geometryKey()).append('\n');
      out.append("expectedSnowLayers=").append(Math.round(frame.snowDepthTarget() * 8.0F)).append('\n');
      out.append("weather=")
         .append(weather.type().id())
         .append(" intensity=")
         .append(weather.intensity())
         .append(" wind=")
         .append(weather.windX())
         .append(',')
         .append(weather.windZ())
         .append('\n');
      out.append(VoxyCategoryDiagnostics.summary()).append('\n');
      out.append(VoxyShaderDiagnostics.summary()).append('\n');
      if (client.player != null) {
         out.append("player=").append(client.player.getX()).append(',').append(client.player.getY()).append(',').append(client.player.getZ()).append('\n');
         out.append("rotation=").append(client.player.getYRot()).append(',').append(client.player.getXRot()).append('\n');
      }

      out.append("voxySnowBlend=")
         .append(TeslesSeasons.CONFIG.voxySnowBlendStartBlocks)
         .append("..")
         .append(TeslesSeasons.CONFIG.voxySnowBlendEndBlocks)
         .append('\n');
      Runtime runtime = Runtime.getRuntime();
      out.append("heapMiB=").append((runtime.totalMemory() - runtime.freeMemory()) / 1048576L).append("/").append(runtime.maxMemory() / 1048576L).append('\n');
      out.append("java=")
         .append(System.getProperty("java.version"))
         .append(" os=")
         .append(System.getProperty("os.name"))
         .append(' ')
         .append(System.getProperty("os.version"))
         .append('\n');
      return out.toString();
   }

   private static void writeWorldSample(Minecraft client, Path path) throws IOException {
      ClientLevel level = client.level;
      if (level != null && client.player != null) {
         int centerX = client.player.getBlockX();
         int centerZ = client.player.getBlockZ();
         int radius = 96;
         int step = 4;

         try (BufferedWriter out = Files.newBufferedWriter(path)) {
            out.write("x,z,height,top_block,top_category,snow_layers,below_block,below_category,base_block,base_category,bottom_slab,flora_cells_window\n");

            for (int z = centerZ - radius; z <= centerZ + radius; z += step) {
               for (int x = centerX - radius; x <= centerX + radius; x += step) {
                  int h = level.getHeight(Types.MOTION_BLOCKING_NO_LEAVES, x, z);
                  BlockPos topPos = new BlockPos(x, h, z);
                  BlockState top = level.getBlockState(topPos);
                  BlockState below = level.getBlockState(topPos.below());
                  SeasonalCategory topCategory = SeasonalClassifier.categoryFor(top);
                  SeasonalCategory belowCategory = SeasonalClassifier.categoryFor(below);
                  int layers = snowLayers(top);
                  BlockPos basePos = topPos.below();
                  if (layers == 0) {
                     layers = snowLayers(below);
                     if (layers > 0) {
                        basePos = topPos.offset(0, -2, 0);
                     }
                  }

                  BlockState base = level.getBlockState(basePos);
                  SeasonalCategory baseCategory = SeasonalClassifier.categoryFor(base);
                  boolean bottomSlab = base.getBlock() instanceof SlabBlock && base.toString().toLowerCase(Locale.ROOT).contains("type=bottom");
                  int floraCells = 0;

                  for (int dy = 3; dy >= -6; dy--) {
                     SeasonalCategory category = SeasonalClassifier.categoryFor(level.getBlockState(topPos.offset(0, dy, 0)));
                     if (category == SeasonalCategory.GROUND_VEGETATION
                        || category == SeasonalCategory.FLOWER
                        || category == SeasonalCategory.MUSHROOM
                        || category == SeasonalCategory.SNOW_REPLACEABLE_DECOR) {
                        floraCells++;
                     }
                  }

                  out.write(
                     x
                        + ","
                        + z
                        + ","
                        + h
                        + ","
                        + blockId(top)
                        + ","
                        + topCategory
                        + ","
                        + layers
                        + ","
                        + blockId(below)
                        + ","
                        + belowCategory
                        + ","
                        + blockId(base)
                        + ","
                        + baseCategory
                        + ","
                        + bottomSlab
                        + ","
                        + floraCells
                        + "\n"
                  );
               }
            }
         }
      }
   }

   private static int snowLayers(BlockState state) {
      return state != null && state.getBlock() instanceof SnowLayerBlock && state.hasProperty(SnowLayerBlock.LAYERS)
         ? (Integer)state.getValue(SnowLayerBlock.LAYERS)
         : 0;
   }

   private static String blockId(BlockState state) {
      if (state == null) {
         return "null";
      } else {
         Identifier id = BuiltInRegistries.BLOCK.getKey(state.getBlock());
         return id == null ? "unknown" : id.toString();
      }
   }

   /**
    * The once-a-second performance series for the whole run.
    *
    * <p>Written at the end rather than streamed, because a capture that is measuring frame time
    * should not be opening a file every second while it does so.
    */
   private static void writePerformanceLog(Path path) {
      try {
         List<String> rows = PerformanceLog.rows();
         StringBuilder out = new StringBuilder(rows.size() * 200 + 256);
         out.append(PerformanceLog.HEADER).append('\n');
         for (String row : rows) {
            out.append(row).append('\n');
         }
         writeText(path, out.toString());
      } catch (Throwable ignored) {
         // A missing performance file must never cost the rest of the bundle.
      }
   }

   private static void writeEnvironmentFiles(Path dir) {
      Path gameDir = FabricLoader.getInstance().getGameDir();

      for (String relative : List.of(
         "config/teslesseasons.json", "config/iris.properties", "config/voxy-config.json", "config/voxy.json", "config/sodium-options.json", "options.txt"
      )) {
         try {
            Path source = gameDir.resolve(relative);
            if (Files.isRegularFile(source)) {
               Path target = dir.resolve("environment").resolve(relative.replace('/', '_'));
               Files.createDirectories(target.getParent());
               Files.copy(source, target, StandardCopyOption.REPLACE_EXISTING);
            }
         } catch (Exception var6) {
         }
      }
   }

   private static void writeLatestLogTail(Path output) {
      Path log = FabricLoader.getInstance().getGameDir().resolve("logs/latest.log");
      if (Files.isRegularFile(log)) {
         int maximum = 2097152;

         try (SeekableByteChannel channel = Files.newByteChannel(log, StandardOpenOption.READ)) {
            long size = channel.size();
            long start = Math.max(0L, size - 2097152L);
            channel.position(start);
            ByteBuffer buffer = ByteBuffer.allocate((int)(size - start));

            while (buffer.hasRemaining() && channel.read(buffer) >= 0) {
            }

            buffer.flip();
            byte[] bytes = new byte[buffer.remaining()];
            buffer.get(bytes);
            Files.write(output, bytes);
         } catch (Exception var12) {
         }
      }
   }

   private static void writeMods(Path path) throws IOException {
      List<ModContainer> mods = new ArrayList<>(FabricLoader.getInstance().getAllMods());
      mods.sort(Comparator.comparing(m -> m.getMetadata().getId()));

      try (BufferedWriter out = Files.newBufferedWriter(path)) {
         for (ModContainer mod : mods) {
            out.write(mod.getMetadata().getId() + "=" + mod.getMetadata().getVersion().getFriendlyString());
            out.newLine();
         }
      }
   }

   private static void writeTimelineHeader(Path path) throws IOException {
      writeText(path, "time,season,phase,phase_progress,autumn,leaves,flowers,mushrooms,dormancy,snow,spring,weather,weather_intensity\n");
   }

   private static void appendTimeline(Path path, long now) {
      try {
         SeasonSnapshot s = ClientSeasonState.get();
         WeatherSnapshot w = ClientWeatherState.get();
         String row = Instant.ofEpochMilli(now)
            + ","
            + s.season()
            + ","
            + s.phase()
            + ","
            + s.phaseProgress()
            + ","
            + s.autumnColor()
            + ","
            + s.leafRetention()
            + ","
            + s.flowerRetention()
            + ","
            + s.mushroomRetention()
            + ","
            + s.groundDormancy()
            + ","
            + s.snowCover()
            + ","
            + s.springFreshness()
            + ","
            + w.type().id()
            + ","
            + w.intensity()
            + "\n";
         Files.writeString(path, row, StandardOpenOption.CREATE, StandardOpenOption.APPEND);
      } catch (Exception var6) {
      }
   }

   private static void finish(Minecraft client, String reason) {
      SeasonDiagnosticRecorder.Session s = session;
      if (s != null) {
         session = null;

         try {
            writeText(s.dir.resolve("client-end.txt"), clientReport(client, "end") + "finishReason=" + reason + "\n");
            PerformanceLog.stop();
            writePerformanceLog(s.dir.resolve("performance.csv"));
            writeLatestLogTail(s.dir.resolve("latest-log-tail.txt"));
            Path zip = s.dir.getParent().resolve("TeslesSeasons-diagnostic-" + s.dir.getFileName() + ".zip");
            zipDirectory(s.dir, zip);
            say(client, "TESLES diagnostic ZIP ready: " + zip.toAbsolutePath());
            TeslesSeasons.LOGGER.info("TESLES diagnostic bundle ready: {}", zip.toAbsolutePath());
         } catch (Exception var4) {
            TeslesSeasons.LOGGER.warn("Could not finalize TESLES diagnostic bundle: {}", var4.toString());
            say(client, "TESLES diagnostic bundle finalization failed: " + var4.getClass().getSimpleName());
         }
      }
   }

   private static void zipDirectory(Path directory, Path zip) throws IOException {
      try (
         ZipOutputStream out = new ZipOutputStream(Files.newOutputStream(zip));
         Stream<Path> paths = Files.walk(directory);
      ) {
         for (Path path : paths.filter(x$0 -> Files.isRegularFile(x$0)).sorted().toList()) {
            String entryName = directory.relativize(path).toString().replace('\\', '/');
            out.putNextEntry(new ZipEntry(entryName));
            Files.copy(path, out);
            out.closeEntry();
         }
      }
   }

   private static void writeText(Path path, String text) throws IOException {
      Files.createDirectories(path.getParent());
      Files.writeString(path, text == null ? "" : text);
   }

   private static void say(Minecraft client, String text) {
      if (client != null && client.player != null) {
         client.player.sendSystemMessage(Component.literal(text));
      }
   }

   private static final class Session {
      final Path dir;
      final DiagnosticCapturePayload.Request request;
      final long startedMillis;
      final Set<String> captured = new HashSet<>();
      long lastTimelineMillis;
      volatile boolean captureBusy;

      Session(Path dir, DiagnosticCapturePayload.Request request, long startedMillis) {
         this.dir = dir;
         this.request = request;
         this.startedMillis = startedMillis;
      }
   }
}
