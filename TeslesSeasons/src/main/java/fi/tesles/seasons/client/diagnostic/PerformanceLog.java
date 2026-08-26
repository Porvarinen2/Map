package fi.tesles.seasons.client.diagnostic;

import fi.tesles.seasons.client.ClientSeasonState;
import fi.tesles.seasons.client.voxy.VoxyShaderDiagnostics;
import fi.tesles.seasons.fix064.client.VoxySeasonRemeshScheduler;
import fi.tesles.seasons.sector.SeasonFrame;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;
import net.minecraft.client.Minecraft;

/**
 * A once-per-second time series of how the game is coping, for the whole of a diagnostic run.
 *
 * <p>A single snapshot says almost nothing about performance. What matters is the shape over a year:
 * whether frame time spikes at a season boundary, whether the LOD set stops being current while the
 * player moves, whether the server falls behind and stays behind. Those are visible in a series and
 * invisible in a capture.
 *
 * <p>Client fields are read here. Server fields arrive as pushed samples and are merged into the same
 * row, so one file lines both sides up against the same clock - which is the only way to tell a client
 * stall from a server one.
 */
public final class PerformanceLog {
   public static final String HEADER =
      "t_ms,season,phase,progress,revision,fps,tick_ms_avg,tick_ms_p95,heap_used_mib,heap_max_mib,"
      + "voxy_sections,voxy_current,voxy_stale,shader_bind_age_ms,player_x,player_y,player_z,"
      + "server_mspt,server_tps,server_loaded,server_urgent,server_ledger_leaves,server_ledger_flora,"
      + "server_snow_placed,server_leaves_removed,server_leaves_restored"
      + ClientCostMeter.header();

   /** Frame times of the last second, for an average and a tail figure. */
   private static final Deque<Long> FRAME_NANOS = new ArrayDeque<>(256);
   private static final List<String> ROWS = new ArrayList<>();
   private static volatile String latestServerSample = "";
   private static volatile String latestServerStatus = "";
   private static long lastFrameNanos;
   private static long startMillis;
   private static boolean running;

   private PerformanceLog() {
   }

   public static synchronized void start() {
      ROWS.clear();
      FRAME_NANOS.clear();
      latestServerSample = "";
      startMillis = System.currentTimeMillis();
      ClientCostMeter.reset();
      lastFrameNanos = 0L;
      running = true;
   }

   public static synchronized void stop() {
      running = false;
   }

   public static boolean isRunning() {
      return running;
   }

   /**
    * Called from the client tick, which fires twenty times a second - so what this measures is the
    * client's tick interval, not its frame time.
    *
    * <p>The distinction cost a reading: an early capture reported a flat 20 fps and a 50 ms frame
    * time for a whole year, which is the tick rate wearing a frame time's name. Frames per second
    * are taken from Minecraft's own counter instead, and these columns say tick.
    */
   public static void onFrame() {
      if (!running) {
         return;
      }
      long now = System.nanoTime();
      if (lastFrameNanos != 0L) {
         synchronized (FRAME_NANOS) {
            FRAME_NANOS.addLast(now - lastFrameNanos);
            while (FRAME_NANOS.size() > 240) {
               FRAME_NANOS.removeFirst();
            }
         }
      }
      lastFrameNanos = now;
   }

   /**
    * Records the newest server sample.
    *
    * <p>Kept as the raw comma-separated tail the server sent, so adding a server-side field needs no
    * change here. It is merged into whichever row is written next.
    */
   public static void acceptServerSample(String csvTail) {
      latestServerSample = csvTail == null ? "" : csvTail;
   }

   /** The server's full human-readable status, pushed alongside the numeric sample. */
   public static void acceptServerStatus(String status) {
      if (status != null && !status.isBlank()) {
         latestServerStatus = status;
      }
   }

   /** Called once a second while a run is active. */
   public static synchronized void sample(Minecraft client) {
      if (!running) {
         return;
      }

      SeasonFrame frame = ClientSeasonState.frame();
      double avgMs = 0.0;
      double p95Ms = 0.0;
      synchronized (FRAME_NANOS) {
         if (!FRAME_NANOS.isEmpty()) {
            long[] sorted = FRAME_NANOS.stream().mapToLong(Long::longValue).sorted().toArray();
            long total = 0L;
            for (long v : sorted) {
               total += v;
            }
            avgMs = total / (double) sorted.length / 1.0E6;
            p95Ms = sorted[Math.min(sorted.length - 1, (int) (sorted.length * 0.95))] / 1.0E6;
         }
      }

      Runtime runtime = Runtime.getRuntime();
      int[] counts = safeSectionCounts(frame);
      double px = client.player == null ? 0.0 : client.player.getX();
      double py = client.player == null ? 0.0 : client.player.getY();
      double pz = client.player == null ? 0.0 : client.player.getZ();

      StringBuilder row = new StringBuilder(220);
      row.append(System.currentTimeMillis() - startMillis).append(',')
         .append(frame.season()).append(',')
         .append(frame.phase()).append(',')
         .append(round(frame.progress())).append(',')
         .append(frame.revision()).append(',')
         .append(currentFps(client)).append(',')
         .append(round(avgMs)).append(',')
         .append(round(p95Ms)).append(',')
         .append((runtime.totalMemory() - runtime.freeMemory()) / 1048576L).append(',')
         .append(runtime.maxMemory() / 1048576L).append(',')
         .append(counts[0]).append(',')
         .append(counts[1]).append(',')
         .append(counts[0] - counts[1]).append(',')
         .append(VoxyShaderDiagnostics.lastSeasonBindAgeMillis()).append(',')
         .append(Math.round(px)).append(',')
         .append(Math.round(py)).append(',')
         .append(Math.round(pz)).append(',')
         .append(latestServerSample.isEmpty() ? ",,,,,,,," : latestServerSample)
         .append(ClientCostMeter.sampleRow());
      ROWS.add(row.toString());
   }

   /** The most recent full server status line, for the end-of-run snapshot. */
   public static String latestServerState() {
      return latestServerStatus.isEmpty() ? "no server status was received during this capture\n" : latestServerStatus;
   }

   public static synchronized List<String> rows() {
      return List.copyOf(ROWS);
   }

   /** Minecraft's own frame counter, which is the only thing here that really is frames. */
   private static int currentFps(Minecraft client) {
      try {
         return client.getFps();
      } catch (Throwable ignored) {
         return -1;
      }
   }

   /** Voxy may not be installed, and the scheduler is only live on a client with it. */
   private static int[] safeSectionCounts(SeasonFrame frame) {
      try {
         return VoxySeasonRemeshScheduler.sectionCounts(frame.geometryKey());
      } catch (Throwable ignored) {
         return new int[]{0, 0};
      }
   }

   private static String round(double v) {
      return String.format(java.util.Locale.ROOT, "%.3f", v);
   }
}
