package fi.tesles.seasons;

import fi.tesles.seasons.network.DiagnosticCapturePayload;
import fi.tesles.seasons.sector.SeasonFrame;
import fi.tesles.seasons.sector.SeasonDirector;
import fi.tesles.seasons.world.SeasonalWorldReconciler;
import java.util.UUID;
import net.fabricmc.fabric.api.networking.v1.ServerPlayNetworking;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerPlayer;

/**
 * Pushes a server-side measurement once a second while a capture is running.
 *
 * <p>The client can measure its own frame time and heap and can see what Voxy is holding, but it
 * cannot see the server's tick time, its chunk queues, or how much the world still owes back. Those
 * are the numbers that separate "the client is struggling" from "the server is behind", which is the
 * first thing worth knowing about any complaint that the world is not keeping up.
 *
 * <p>Sampling is only active for the player who asked for a capture, and only for its duration.
 * There is no ambient cost.
 */
public final class ServerDiagnosticSampler {
   /** Field order must match the tail of {@code PerformanceLog.HEADER}. */
   private static final int SAMPLE_INTERVAL_TICKS = 20;

   private static volatile UUID target;
   private static volatile long endMillis;
   private static long lastTickNanos;
   private static double msptAverage;
   private static int tickCounter;

   private ServerDiagnosticSampler() {
   }

   /** Begins sampling for {@code player}, for {@code durationSeconds} plus a margin. */
   public static void begin(ServerPlayer player, int durationSeconds) {
      target = player.getUUID();
      endMillis = System.currentTimeMillis() + (durationSeconds + 30L) * 1000L;
      msptAverage = 0.0;
      tickCounter = 0;
      lastTickNanos = 0L;
   }

   public static void stop() {
      target = null;
   }

   /**
    * Called every server tick. Measures tick time continuously and sends once a second.
    *
    * <p>Tick time is smoothed rather than sampled, because a once-a-second reading of a 50 ms tick
    * mostly measures where in the tick the sample landed.
    */
   public static void tick(MinecraftServer server) {
      long now = System.nanoTime();
      if (lastTickNanos != 0L) {
         double ms = (now - lastTickNanos) / 1.0E6;
         msptAverage = msptAverage == 0.0 ? ms : msptAverage * 0.9 + ms * 0.1;
      }
      lastTickNanos = now;

      UUID id = target;
      if (id == null) {
         return;
      }
      if (System.currentTimeMillis() > endMillis) {
         target = null;
         return;
      }
      if (++tickCounter < SAMPLE_INTERVAL_TICKS) {
         return;
      }
      tickCounter = 0;

      ServerPlayer player = server.getPlayerList().getPlayer(id);
      if (player == null) {
         return;
      }

      try {
         ServerPlayNetworking.send(player, DiagnosticCapturePayload.sample(sampleRow()));
      } catch (Throwable ignored) {
         // A capture must never be the reason a tick throws.
      }
   }

   /** The comma-separated tail merged into the client's row. */
   private static String sampleRow() {
      SeasonFrame frame = SeasonDirector.currentFrame();
      SeasonalWorldReconciler.Counters c = SeasonalWorldReconciler.counters();
      double mspt = msptAverage;
      double tps = mspt <= 0.0 ? 20.0 : Math.min(20.0, 1000.0 / mspt);
      return String.format(java.util.Locale.ROOT, "%.2f,%.2f,%d,%d,%d,%d,%d,%d,%d",
         mspt, tps, c.loaded(), c.urgent(), c.ledgerLeaves(), c.ledgerFlora(),
         c.snowPlaced(), c.leavesRemoved(), c.leavesRestored());
   }
}
