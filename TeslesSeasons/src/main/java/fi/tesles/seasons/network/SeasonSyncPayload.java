package fi.tesles.seasons.network;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import fi.tesles.seasons.TeslesSeasons;
import fi.tesles.seasons.api.SeasonSnapshot;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.codec.ByteBufCodecs;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload.Type;

public record SeasonSyncPayload(String json) implements CustomPacketPayload {
   private static final Gson GSON = new GsonBuilder().create();
   public static final Type<SeasonSyncPayload> TYPE = new Type(TeslesSeasons.id("season_state"));
   public static final StreamCodec<FriendlyByteBuf, SeasonSyncPayload> CODEC = ByteBufCodecs.STRING_UTF8
      .map(SeasonSyncPayload::new, SeasonSyncPayload::json)
      .cast();

   public static SeasonSyncPayload from(SeasonSnapshot snapshot) {
      return new SeasonSyncPayload(GSON.toJson(SeasonWireState.from(snapshot)));
   }

   public SeasonSnapshot decode() {
      SeasonWireState state = (SeasonWireState)GSON.fromJson(this.json, SeasonWireState.class);
      return state == null ? SeasonSnapshot.summerDefault(7302026L) : state.toSnapshot();
   }

   public Type<? extends CustomPacketPayload> type() {
      return TYPE;
   }
}
