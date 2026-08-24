package fi.tesles.seasons.client;

import fi.tesles.seasons.weather.WeatherSnapshot;

public final class ClientWeatherState {
   private static volatile WeatherSnapshot snapshot = WeatherSnapshot.clear();

   private ClientWeatherState() {
   }

   public static WeatherSnapshot get() {
      return snapshot;
   }

   public static void accept(WeatherSnapshot next) {
      snapshot = next == null ? WeatherSnapshot.clear() : next;
   }

   public static void reset() {
      snapshot = WeatherSnapshot.clear();
   }
}
