import * as fs from "fs";
import * as path from "path";

export type PoiType =
  | "town" | "village" | "farm" | "military" | "bunker" | "police" | "hospital"
  | "gas" | "warehouse" | "airfield" | "forest" | "lake" | "river" | "coast"
  | "trader" | "ruins";

export interface Poi {
  id: string;
  label: string;
  type: PoiType;
  x: number;
  y: number;
  /** 0 = nothing worth taking, 5 = military / bunker grade. */
  lootTier: number;
  /** Baseline chance of trouble per visit (puppets, sentries, other survivors). */
  danger: number;
  water: boolean;
  shelter: boolean;
  underground?: boolean;
  farmable?: boolean;
  game?: boolean;
  fish?: boolean;
  trade?: boolean;
}

export interface WorldMap {
  islandSizeM: number;
  pois: Poi[];
  byId: Map<string, Poi>;
}

export function loadMap(): WorldMap {
  const file = path.resolve(__dirname, "../../data/world/pois.json");
  const raw = JSON.parse(fs.readFileSync(file, "utf8")) as { islandSizeM: number; pois: Poi[] };
  return { ...raw, byId: new Map(raw.pois.map((p) => [p.id, p])) };
}

export const distance = (
  a: { x: number; y: number },
  b: { x: number; y: number },
): number => Math.hypot(a.x - b.x, a.y - b.y);
