package fi.tesles.seasons.weather;

public record WeatherSnapshot(TeslesWeatherType type, double intensity, double windX, double windZ) {
   public static WeatherSnapshot clear() {
      return new WeatherSnapshot(TeslesWeatherType.CLEAR, 0.0, 0.0, 0.0);
   }
}
