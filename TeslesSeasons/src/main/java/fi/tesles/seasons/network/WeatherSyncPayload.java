package fi.tesles.seasons.network;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.weather.TeslesWeatherType;
import fi.tesles.seasons.weather.WeatherSnapshot;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.codec.ByteBufCodecs;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload.Type;

public record WeatherSyncPayload(String json) implements CustomPacketPayload {
   private static final Gson GSON = new GsonBuilder().create();
   public static final Type<WeatherSyncPayload> TYPE = new Type(TeslesSeasons.id("weather_state"));
   public static final StreamCodec<FriendlyByteBuf, WeatherSyncPayload> CODEC = ByteBufCodecs.STRING_UTF8
      .map(WeatherSyncPayload::new, WeatherSyncPayload::json)
      .cast();

   public static WeatherSyncPayload from(WeatherSnapshot snapshot) {
      return new WeatherSyncPayload(GSON.toJson(new WeatherSyncPayload.Wire(snapshot.type().id(), snapshot.intensity(), snapshot.windX(), snapshot.windZ())));
   }

   public WeatherSnapshot decode() {
      WeatherSyncPayload.Wire wire = (WeatherSyncPayload.Wire)GSON.fromJson(this.json, WeatherSyncPayload.Wire.class);
      if (wire == null) {
         return WeatherSnapshot.clear();
      } else {
         TeslesWeatherType type = TeslesWeatherType.fromId(wire.typeId());
         if (type == null) {
            type = TeslesWeatherType.CLEAR;
         }

         return new WeatherSnapshot(type, wire.intensity(), wire.windX(), wire.windZ());
      }
   }

   public Type<? extends CustomPacketPayload> type() {
      return TYPE;
   }

   private record Wire(String typeId, double intensity, double windX, double windZ) {
   }
}
