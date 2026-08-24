package fi.tesles.seasons.client.render;

public enum SeasonalCategory {
   NONE(0),
   DECIDUOUS_LEAVES(1),
   GROUND_VEGETATION(2),
   EVERGREEN_LEAVES(3),
   SEASONAL_GROUND(4),
   FLOWER(5),
   FROSTABLE_SURFACE(6),
   SNOW_OVERLAY_PLANT(7),
   MUSHROOM(8),
   SNOW_REPLACEABLE_DECOR(9),
   SEASONAL_SNOW(10);

   private final int voxyId;

   private SeasonalCategory(int voxyId) {
      this.voxyId = voxyId;
   }

   public int voxyId() {
      return this.voxyId;
   }
}
