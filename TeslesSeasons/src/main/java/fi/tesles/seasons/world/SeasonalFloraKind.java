package fi.tesles.seasons.world;

/**
 * Seasonal flora categories. One registry decides which of these a block is; nothing else may
 * guess.
 *
 * <p>{@code BERRY} is deliberately separate from {@code PLANT}. Wild berry bushes follow their
 * own retention channel and their own field salt, so their season does not have to march in
 * lockstep with ground plants and they do not appear and vanish on exactly the same
 * coordinates.
 *
 * <p>New constants must be appended. The restore ledger stores the enum by name, so appending
 * is safe for existing worlds, but reordering would silently re-label every saved entry.
 */
public enum SeasonalFloraKind {
   NONE,
   PLANT,
   FLOWER,
   MUSHROOM,
   BERRY;
}
