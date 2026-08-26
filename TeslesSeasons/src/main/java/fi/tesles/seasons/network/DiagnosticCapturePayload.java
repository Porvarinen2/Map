package fi.tesles.seasons.network;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import fi.tesles.seasons.TeslesSeasons;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.codec.ByteBufCodecs;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload.Type;

public record DiagnosticCapturePayload(String json) implements CustomPacketPayload {
   private static final Gson GSON = new GsonBuilder().create();
   public static final Type<DiagnosticCapturePayload> TYPE = new Type(TeslesSeasons.id("diagnostic_capture"));
   public static final StreamCodec<FriendlyByteBuf, DiagnosticCapturePayload> CODEC = ByteBufCodecs.STRING_UTF8
      .map(DiagnosticCapturePayload::new, DiagnosticCapturePayload::json)
      .cast();

   public static DiagnosticCapturePayload single(String serverSummary) {
      return from(new DiagnosticCapturePayload.Request("single", 0, System.currentTimeMillis(), serverSummary));
   }

   public static DiagnosticCapturePayload year(int durationSeconds, String serverSummary) {
      return from(new DiagnosticCapturePayload.Request("year", durationSeconds, System.currentTimeMillis(), serverSummary));
   }

   /**
    * A periodic server-side measurement, pushed while a capture is running.
    *
    * <p>The client cannot see the server's tick time, chunk queues or ledger sizes, and those are
    * exactly the numbers that separate a client stall from a server one. Sending them on the same
    * second the client samples itself is what lets one file line the two up against one clock.
    *
    * <p>The payload is the raw comma-separated tail of the row, so adding a server-side field needs
    * no change on the receiving side.
    */
   /** Toggles the client's status panel. The command tree is server-side; the panel is not. */
   public static DiagnosticCapturePayload hud(String mode) {
      return from(new DiagnosticCapturePayload.Request("hud", 0, System.currentTimeMillis(), mode));
   }

   public static DiagnosticCapturePayload sample(String csvTail) {
      return from(new DiagnosticCapturePayload.Request("sample", 0, System.currentTimeMillis(), csvTail));
   }

   private static DiagnosticCapturePayload from(DiagnosticCapturePayload.Request request) {
      return new DiagnosticCapturePayload(GSON.toJson(request));
   }

   public DiagnosticCapturePayload.Request decode() {
      DiagnosticCapturePayload.Request request = (DiagnosticCapturePayload.Request)GSON.fromJson(this.json, DiagnosticCapturePayload.Request.class);
      return request == null ? new DiagnosticCapturePayload.Request("single", 0, System.currentTimeMillis(), "") : request;
   }

   public Type<? extends CustomPacketPayload> type() {
      return TYPE;
   }

   public record Request(String mode, int durationSeconds, long requestedAtMillis, String serverSummary) {
      public boolean isYear() {
         return "year".equalsIgnoreCase(this.mode);
      }

      public boolean isSample() {
         return "sample".equalsIgnoreCase(this.mode);
      }

      public boolean isHud() {
         return "hud".equalsIgnoreCase(this.mode);
      }
   }
}
