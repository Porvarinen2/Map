package fi.tesles.seasons.client.diagnostic;

import java.util.concurrent.atomic.AtomicLong;

/**
 * Where the client's time goes, per subsystem, sampled into the performance series.
 *
 * <p>Added because a capture measured the frame rate stepping from 27 to 10 at the exact moment
 * Winter arrived and never recovering - not through the thaw, not through Spring, not once the
 * world was back to full canopy and no snow. The server was untouched throughout, so the cost is
 * entirely on this side, and nothing in the bundle could say which part of it.
 *
 * <p>Every meter is a running nanosecond total and a call count. They are read and reset once a
 * second, so a row reports what that second cost rather than what the session has cost, and a step
 * change lands on the row where it happened.
 *
 * <p>Instrumentation has to be cheaper than what it measures. Each meter is two atomic adds around
 * work that runs in the hundreds of microseconds, and the whole thing compiles out of the hot path
 * when the class is never touched.
 */
public final class ClientCostMeter {
   /** Projecting the season onto one Voxy LOD section at mesh-build time. */
   public static final ClientCostMeter LOD_PROJECTION = new ClientCostMeter("lod_projection");
   /** Removing leaves the frame has dropped from a section. */
   public static final ClientCostMeter LEAF_STRIP = new ClientCostMeter("leaf_strip");
   /** Clearing seasonal snow out of a section's columns. */
   public static final ClientCostMeter SNOW_CLEAR = new ClientCostMeter("snow_clear");
   /** Adding seasonal snow to a section's columns. */
   public static final ClientCostMeter SNOW_ADD = new ClientCostMeter("snow_add");
   /** Rebuilding near-field chunk meshes after a season change. */
   public static final ClientCostMeter NEAR_REFRESH = new ClientCostMeter("near_refresh");

   private static final ClientCostMeter[] ALL = {
      LOD_PROJECTION, LEAF_STRIP, SNOW_CLEAR, SNOW_ADD, NEAR_REFRESH
   };

   private final String id;
   private final AtomicLong nanos = new AtomicLong();
   private final AtomicLong calls = new AtomicLong();

   private ClientCostMeter(String id) {
      this.id = id;
   }

   /** Adds one measured interval. Call as {@code meter.record(System.nanoTime() - start)}. */
   public void record(long elapsedNanos) {
      this.nanos.addAndGet(elapsedNanos);
      this.calls.incrementAndGet();
   }

   /** Column names for the performance series, in the order {@link #sampleRow()} writes them. */
   public static String header() {
      StringBuilder out = new StringBuilder(128);
      for (ClientCostMeter meter : ALL) {
         out.append(',').append(meter.id).append("_ms").append(',').append(meter.id).append("_calls");
      }
      return out.toString();
   }

   /** Reads and resets every meter. */
   public static String sampleRow() {
      StringBuilder out = new StringBuilder(128);
      for (ClientCostMeter meter : ALL) {
         long ns = meter.nanos.getAndSet(0L);
         long n = meter.calls.getAndSet(0L);
         out.append(',').append(String.format(java.util.Locale.ROOT, "%.2f", ns / 1.0E6)).append(',').append(n);
      }
      return out.toString();
   }

   public static void reset() {
      for (ClientCostMeter meter : ALL) {
         meter.nanos.set(0L);
         meter.calls.set(0L);
      }
   }
}
