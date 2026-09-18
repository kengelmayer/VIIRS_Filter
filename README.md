# VIIRS-Filter für aktuelle Vegetationsbrände

Dieses Projekt erzeugt stündlich eine rollende GeoJSON-Datei mit VIIRS-Hotspots
der letzten 24 Stunden,
die wahrscheinlich auf Vegetation liegen. Es verwendet den öffentlichen
ArcGIS-Living-Atlas-Layer und ESA WorldCover 2021. Die räumliche Analyse läuft
in R auf GitHub Actions und verbraucht dadurch keine ArcGIS-Analysecredits.

## Ablauf

1. Das Skript fragt den aktuell kleinsten Wert von `hours_old` ab. Dieser Wert
   ist gewöhnlich 2 oder 3, wird aber bewusst nicht fest codiert.
2. Es lädt den neuesten Altersblock plus eine Stunde Überlappung. Bereits
   vorhandene Detektionen werden über einen stabilen Schlüssel aus Satellit,
   Aufnahmezeit und Koordinaten entfernt.
3. Die zunächst leere Datei füllt sich mit jedem Stundenlauf, bis das
   24-Stunden-Fenster vollständig aufgebaut ist. Es gibt keinen großen
   Erstimport.
4. Für jeden neuen Hotspot werden neun Positionen innerhalb des durch `scan`
   und `track` angenäherten VIIRS-Pixels in ESA WorldCover geprüft.
5. Mindestens 50 Prozent der gültigen Stichproben müssen Vegetationsklassen
   sein. Ein Punkt mit `Built-up` direkt im Pixelzentrum wird verworfen.
6. Detektionen, deren `acq_time` mehr als 24 Stunden zurückliegt, werden aus
   der Datei entfernt. Das gespeicherte Quellfeld `hours_old` wird dafür nicht
   verwendet, weil es nach dem Einlesen nicht weiter altert.

Standardmäßig gelten diese WorldCover-Klassen als Vegetation:

- 10 Tree cover
- 20 Shrubland
- 30 Grassland
- 40 Cropland
- 90 Herbaceous wetland
- 95 Mangroves
- 100 Moss and lichen

Zusätzlich werden nur VIIRS-Punkte mit `nominal` oder `high` Confidence
verarbeitet.

## Lokaler Start

Benötigt werden R sowie die Pakete `curl`, `jsonlite` und `terra`.

```bash
Rscript tests/test_helpers.R
Rscript R/update_viirs.R
```

Das Ergebnis wird kompakt nach
`site/viirs_vegetation_24h.geojson` geschrieben. Zusätzlich enthält
`site/status.json` eine kleine Statuszusammenfassung, damit die Übersichtsseite
nicht die gesamte GeoJSON-Datei laden muss.

## GitHub Pages als zustandsbehafteter Artefaktspeicher

Der Workflow `.github/workflows/update-viirs.yml` läuft stündlich bei Minute
17. Er schreibt die große Datendatei nicht mehr in die Git-Historie. Stattdessen
arbeitet jeder Lauf so:

1. Die zuletzt veröffentlichte GeoJSON-Datei wird von der bestehenden
   GitHub-Pages-URL heruntergeladen.
2. R ergänzt neue, noch unbekannte VIIRS-Punkte und entfernt Einträge außerhalb
   des rollenden 24-Stunden-Fensters.
3. Der Ordner `site/` wird als kurzlebiges Actions-Artefakt hochgeladen.
4. GitHub Pages ersetzt die bisherige Veröffentlichung atomar durch dieses
   Artefakt.

Das Actions-Artefakt ist nur das Transportpaket. Die aktive Pages-Veröffentlichung
bleibt bestehen, auch wenn das Transportartefakt nach einem Tag abläuft. Wenn
ein neuer Lauf fehlschlägt, bleibt die zuletzt erfolgreich veröffentlichte
Version online.

### Einmalige Aktivierung

1. Repository auf GitHub öffnen.
2. **Settings → Pages** öffnen.
3. Unter **Build and deployment → Source** die Option **GitHub Actions** wählen.
4. Den Workflow einmal über **Actions → Update and publish filtered VIIRS
   hotspots → Run workflow** starten.

Die konkret benötigten Rechte `contents: read`, `pages: write` und
`id-token: write` stehen bereits im Workflow. Der erste Lauf findet noch keine
bestehende Pages-Datei und beginnt deshalb mit einer leeren FeatureCollection.
Die Datei füllt sich danach stündlich.

Die öffentliche Pages-URL wird nach dem ersten Deploy unter **Settings → Pages**
angezeigt. Die GeoJSON-URL für ArcGIS lautet anschließend:

```text
https://OWNER.github.io/REPOSITORY/viirs_vegetation_24h.geojson
```

In Map Viewer: **Hinzufügen → Layer aus URL → GeoJSON**.

Bei einer eigenen GitHub-Pages-Domain kann die Basis-URL abweichen. Der Workflow
ermittelt sie automatisch über `actions/configure-pages`.

## Konfiguration

Die wichtigsten Umgebungsvariablen sind:

| Variable | Standard | Bedeutung |
|---|---:|---|
| `ROLLING_WINDOW_HOURS` | `24` | Länge des Ausgabefensters |
| `SOURCE_OVERLAP_HOURS` | `1` | zusätzliche Altersblöcke gegen Lücken |
| `BOOTSTRAP_HOURS` | `0` | optionaler einmaliger Rückblick bei leerer Datei |
| `LANDCOVER_GRID_SIZE` | `3` | `1` für Mittelpunkt, `3` für 3×3-Footprint |
| `VEGETATION_SHARE_THRESHOLD` | `0.5` | erforderlicher Vegetationsanteil |
| `REJECT_BUILT_CENTER` | `true` | Industrie-/Siedlungszentrum ausschließen |
| `VEGETATION_CODES` | `10,20,30,40,90,95,100` | erlaubte WorldCover-Klassen |
| `VIIRS_CONFIDENCE` | `nominal,high` | erlaubte VIIRS-Qualitätsklassen |

## Datenquellen und Grenzen

- VIIRS: NASA FIRMS, bereitgestellt als Esri Living Atlas Live Feed,
  Item-ID `dece90af1a0242dcbf0ca36d30276aa3`.
- Landcover: ESA WorldCover 2021 v200. Die Cloud-Optimized GeoTIFF-Kacheln
  werden direkt aus dem öffentlichen ESA-AWS-Bucket gelesen.
- Das 3×3-Raster ist eine Annäherung an den VIIRS-Footprint; dessen genaue
  Orientierung entlang der Satellitenbahn ist im Feature-Layer nicht enthalten.
- Ein Landcover-Filter kann dauerhafte Wärmequellen reduzieren, aber nicht
  vollständig erkennen. Eine zeitlich aufgebaute Maske wiederkehrender
  Industrie-Hotspots ist als zweiter Filter weiterhin sinnvoll.
- Die Pages-Veröffentlichung enthält immer nur den neuesten Stand; sie ist kein
  langfristiges Datenarchiv.
- GitHub Pages unterstützt Artefakte offiziell bis etwa 1 GB. Der Workflow
  bricht vorsorglich ab, falls die GeoJSON-Datei 900 MiB überschreitet.
