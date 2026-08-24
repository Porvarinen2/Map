package fi.tesles.seasons.calendar;

import java.util.Locale;

public enum Season {
   SPRING,
   SUMMER,
   AUTUMN,
   WINTER;

   public static Season parse(String value, Season fallback) {
      if (value == null) {
         return fallback;
      } else {
         try {
            return valueOf(value.trim().toUpperCase(Locale.ROOT));
         } catch (IllegalArgumentException var3) {
            return fallback;
         }
      }
   }

   public float dynamicTreesMidpoint() {
      return switch (this) {
         case SPRING -> 0.5F;
         case SUMMER -> 1.5F;
         case AUTUMN -> 2.5F;
         case WINTER -> 3.5F;
      };
   }
}
