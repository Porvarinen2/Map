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
   }
}
