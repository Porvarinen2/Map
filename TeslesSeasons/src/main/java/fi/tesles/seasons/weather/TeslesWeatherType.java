package fi.tesles.seasons.weather;

import java.util.Locale;

public enum TeslesWeatherType {
   CLEAR("clear", "Clear", TeslesWeatherType.Precipitation.NONE, false, false, 0.0, 0.0, 0.0),
   CLOUDY("cloudy", "Cloudy", TeslesWeatherType.Precipitation.NONE, true, false, 0.0, 0.0, 0.25),
   DRIZZLE("drizzle", "Drizzle", TeslesWeatherType.Precipitation.RAIN, true, false, 0.28, 0.0, 0.35),
   RAIN("rain", "Rain", TeslesWeatherType.Precipitation.RAIN, true, false, 0.68, 0.0, 0.48),
   HEAVY_RAIN("heavy_rain", "Heavy rain", TeslesWeatherType.Precipitation.RAIN, true, false, 1.0, 0.0, 0.65),
   THUNDERSTORM("thunderstorm", "Thunderstorm", TeslesWeatherType.Precipitation.RAIN, true, true, 1.0, 0.0, 0.9),
   LIGHT_SNOW("light_snow", "Light snow", TeslesWeatherType.Precipitation.SNOW, true, false, 0.32, 0.55, 0.42),
   SNOW("snow", "Snow", TeslesWeatherType.Precipitation.SNOW, true, false, 0.62, 1.0, 0.55),
   HEAVY_SNOW("heavy_snow", "Heavy snow", TeslesWeatherType.Precipitation.SNOW, true, false, 0.86, 1.65, 0.72),
   BLIZZARD("blizzard", "Blizzard", TeslesWeatherType.Precipitation.SNOW, true, false, 1.0, 2.4, 1.0);

   private final String id;
   private final String displayName;
   private final TeslesWeatherType.Precipitation precipitation;
   private final boolean overcast;
   private final boolean thunder;
   private final double visualIntensity;
   private final double snowAccumulationMultiplier;
   private final double windStrength;

   private TeslesWeatherType(
      String id,
      String displayName,
      TeslesWeatherType.Precipitation precipitation,
      boolean overcast,
      boolean thunder,
      double visualIntensity,
      double snowAccumulationMultiplier,
      double windStrength
   ) {
      this.id = id;
      this.displayName = displayName;
      this.precipitation = precipitation;
      this.overcast = overcast;
      this.thunder = thunder;
      this.visualIntensity = visualIntensity;
      this.snowAccumulationMultiplier = snowAccumulationMultiplier;
      this.windStrength = windStrength;
   }

   public String id() {
      return this.id;
   }

   public String displayName() {
      return this.displayName;
   }

   public TeslesWeatherType.Precipitation precipitation() {
      return this.precipitation;
   }

   public boolean overcast() {
      return this.overcast;
   }

   public boolean thunder() {
      return this.thunder;
   }

   public double visualIntensity() {
      return this.visualIntensity;
   }

   public double snowAccumulationMultiplier() {
      return this.snowAccumulationMultiplier;
   }

   public double windStrength() {
      return this.windStrength;
   }

   public boolean isSnow() {
      return this.precipitation == TeslesWeatherType.Precipitation.SNOW;
   }

   public boolean isRain() {
      return this.precipitation == TeslesWeatherType.Precipitation.RAIN;
   }

   public boolean hasPrecipitation() {
      return this.precipitation != TeslesWeatherType.Precipitation.NONE;
   }

   public int snowSweepIntervalTicks() {
      return switch (this) {
         case LIGHT_SNOW -> 420;
         case SNOW -> 240;
         case HEAVY_SNOW -> 120;
         case BLIZZARD -> 60;
         default -> Integer.MAX_VALUE;
      };
   }

   public static TeslesWeatherType fromId(String value) {
      if (value == null) {
         return null;
      } else {
         String normalized = value.trim().toLowerCase(Locale.ROOT).replace('-', '_').replace(' ', '_');

         for (TeslesWeatherType type : values()) {
            if (type.id.equals(normalized) || type.name().toLowerCase(Locale.ROOT).equals(normalized)) {
               return type;
            }
         }

         return null;
      }
   }

   public static enum Precipitation {
      NONE,
      RAIN,
      SNOW;
   }
}
