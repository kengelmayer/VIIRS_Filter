# VIIRS Vegetation Hotspots

Dieses Projekt erzeugt stündlich eine rollende GeoJSON-Datei mit gefilterten
VIIRS-Thermal-Hotspots der letzten **7 Tage (168 Stunden)**. Ziel ist eine
leichtgewichtige, öffentlich erreichbare Datenquelle für ArcGIS Map Viewer und
ArcGIS Dashboards, ohne die Hotspots als kostenpflichtigen ArcGIS Hosted Feature
Layer speichern zu müssen.

Die Verarbeitung läuft in **R** auf **GitHub Actions**. **Cloudflare Workers**
übernimmt nur die stündliche Zeitsteuerung, während **Cloudflare R2** den
aktuellen Datensatz persistent speichert und öffentlich bereitstellt.

## Architektur

```text
Cloudflare Cron Trigger
        |
        v
Cloudflare Worker
        |
        | GitHub workflow_dispatch
        v
GitHub Actions
        |
        | 1. aktuellen GeoJSON-Zustand aus R2 laden
        | 2. neue VIIRS-Punkte laden
        | 3. WorldCover-Filter anwenden
        | 4. Land zuordnen
        | 5. auf 168 Stunden beschneiden
        v
Cloudflare R2
        |
        +-- viirs_vegetation.geojson
        +-- status.json
        |
        v
ArcGIS Map Viewer / Dashboard
```

GitHub Pages wird für die Datenauslieferung nicht mehr verwendet.

## Datenverarbeitung

Der zentrale Workflow liegt unter:

```text
.github/workflows/update-viirs.yml
```

Die eigentliche Verarbeitung erfolgt in:

```text
R/update_viirs.R
R/lib_viirs.R
```

Pro Lauf passiert Folgendes:

1. Die zuletzt veröffentlichte `viirs_vegetation.geojson` wird aus Cloudflare
   R2 geladen.
2. Das Skript fragt beim VIIRS-Quellservice das aktuell kleinste
   `hours_old` ab.
3. Es lädt nur den neuesten Altersblock plus die konfigurierte Überlappung.
4. Bereits vorhandene Detektionen werden über einen stabilen Schlüssel aus
   Satellit, Aufnahmezeit und Koordinaten entfernt.
5. Nur neue Detektionen werden räumlich weiterverarbeitet.
6. Für jeden neuen Hotspot wird ein angenäherter VIIRS-Footprint anhand von
   `scan` und `track` erzeugt und mit ESA WorldCover 2021 geprüft.
7. Nur Punkte mit ausreichend Vegetationsanteil werden übernommen.
8. Für die verbleibenden neuen Punkte wird per Point-in-Polygon das Land aus
   Natural Earth ermittelt.
9. Alte Detektionen außerhalb des 168-Stunden-Fensters werden entfernt.
10. Der komplette schlanke GeoJSON-Datensatz wird neu geschrieben und nach R2
    hochgeladen.

Die teuren räumlichen Schritte werden damit nur für tatsächlich neue VIIRS-
Detektionen ausgeführt.

## VIIRS-Filter

Standardmäßig werden nur VIIRS-Punkte mit diesen Confidence-Klassen
verarbeitet:

```text
nominal
high
```

Der Quellservice wird inkrementell abgefragt. Standardmäßig wird der aktuell
neueste Altersblock plus eine Stunde Überlappung geladen:

```text
SOURCE_OVERLAP_HOURS=1
```

Die Überlappung reduziert das Risiko, durch zeitversetzte Aktualisierungen des
Quellservices Detektionen zu verpassen. Bereits bekannte Punkte werden danach
dedupliziert.

## Vegetationsfilter mit ESA WorldCover

Für jeden neuen VIIRS-Punkt werden standardmäßig neun Positionen in einem
3x3-Raster innerhalb des angenäherten VIIRS-Footprints geprüft.

Als Vegetation gelten derzeit:

| Code | WorldCover-Klasse |
|---:|---|
| 10 | Tree cover |
| 20 | Shrubland |
| 30 | Grassland |
| 40 | Cropland |
| 90 | Herbaceous wetland |
| 95 | Mangroves |
| 100 | Moss and lichen |

Mindestens **50 %** der gültigen Stichproben müssen in einer dieser Klassen
liegen:

```text
VEGETATION_SHARE_THRESHOLD=0.5
```

Zusätzlich wird ein Punkt verworfen, wenn das Pixelzentrum eindeutig der
WorldCover-Klasse `50 = Built-up` entspricht.

Die WorldCover-Daten werden nicht lokal gespeichert. Das Skript liest die
benötigten Cloud-Optimized GeoTIFF-Kacheln direkt aus dem öffentlichen
ESA-WorldCover-Bucket.

## Länderzuordnung

Die Datei

```text
data/ne_50m_admin_0_countries.geojson
```

enthält die Natural-Earth-Länderpolygone.

Nur **neue und bereits durch WorldCover akzeptierte** Hotspots werden räumlich
mit diesen Polygonen verschnitten. Als Ländername wird das Natural-Earth-Feld

```text
SOVEREIGNT
```

verwendet.

Bereits gespeicherte Punkte werden nicht erneut räumlich geprüft. Dadurch
bleibt der stündliche Rechenaufwand gering.

## Öffentlicher GeoJSON-Datensatz

Der veröffentlichte Datensatz heißt in R2:

```text
viirs_vegetation.geojson
```

Jedes Feature enthält nur die Attribute, die im ArcGIS-Dashboard benötigt
werden:

| Feld | Bedeutung |
|---|---|
| `acq_time` | VIIRS-Aufnahmezeit in UTC |
| `hours_old` | Alter der Detektion in Stunden |
| `frp` | Fire Radiative Power |
| `landcover_center_class` | WorldCover-Klasse am Pixelzentrum |
| `country` | Natural-Earth-`SOVEREIGNT` des Punktes |

Zusätzlich besitzt jedes GeoJSON-Feature eine stabile `id`, die intern für die
Deduplizierung verwendet wird.

`hours_old` wird bei **jedem Workflow-Lauf für alle gespeicherten Punkte neu
berechnet**. Dadurch bleibt das Feld für Dashboard-Filter aktuell und ist nicht
nur das Alter zum Zeitpunkt des ursprünglichen Imports.

Nicht benötigte VIIRS- und Verarbeitungsfelder wie `satellite`, `confidence`,
`scan_km`, `track_km`, `vegetation_share` oder
`source_hours_old_at_ingest` werden nicht veröffentlicht.

## Rollendes Zeitfenster

Der Produktionsworkflow verwendet:

```text
ROLLING_WINDOW_HOURS=168
```

Damit enthält die Datei maximal die letzten sieben Tage.

Das System arbeitet inkrementell. Wird das Zeitfenster vergrößert, werden
historische Daten nicht automatisch vollständig rückwirkend geladen. Der
Datensatz wächst mit den folgenden Stundenläufen in das größere Fenster hinein.

## Cloudflare R2

R2 ist gleichzeitig:

- persistenter Zustand zwischen Workflow-Läufen,
- öffentlicher Speicher für den GeoJSON-Datensatz,
- Speicher für die kleine Statusdatei.

Verwendeter Bucket:

```text
viirs-data
```

Veröffentlichte Objekte:

```text
viirs_vegetation.geojson
status.json
```

Der GitHub-Workflow lädt zu Beginn den aktuellen GeoJSON-Datensatz aus R2 und
überschreibt ihn nach erfolgreicher Verarbeitung.

Dadurch wird die große Datei weder in der Git-Historie gespeichert noch über
GitHub Pages ausgeliefert.

### R2-Zugang für GitHub Actions

Im Repository müssen unter

**Settings -> Secrets and variables -> Actions -> Repository secrets**

folgende Secrets existieren:

```text
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
R2_ENDPOINT
```

Der verwendete R2-API-Token sollte auf den Bucket `viirs-data` beschränkt sein
und nur die benötigten Object-Read/Write-Rechte besitzen.

Die Zugangsdaten dürfen niemals im Repository gespeichert werden.

### Öffentliche R2-URL

Ohne eigene Domain kann der von Cloudflare erzeugte öffentliche
`r2.dev`-Endpunkt verwendet werden:

```text
https://pub-<cloudflare-id>.r2.dev/viirs_vegetation.geojson
```

Die konkrete `pub-...`-Adresse wird in den R2-Bucket-Einstellungen angezeigt.

Ein eigener Custom Domain ist technisch nicht erforderlich. Für sehr hohe
öffentliche Last kann ein Custom Domain später sinnvoll sein, insbesondere wenn
Cloudflare-CDN-Caching genutzt werden soll.

### CORS

Damit ArcGIS den GeoJSON-Datensatz direkt aus einem Browser laden kann, muss
der R2-Bucket öffentliche GET/HEAD-Anfragen zulassen. Eine passende öffentliche
CORS-Konfiguration ist beispielsweise:

```json
[
  {
    "AllowedOrigins": ["*"],
    "AllowedMethods": ["GET", "HEAD"]
  }
]
```

## Cloudflare Worker und Zeitsteuerung

GitHub Actions wird nicht über GitHubs eigenen Cron-Scheduler gestartet.

Stattdessen besitzt der Workflow nur:

```yaml
on:
  workflow_dispatch:
```

Ein Cloudflare Worker besitzt einen stündlichen Cron Trigger und sendet über die
GitHub API einen `workflow_dispatch` an:

```text
kengelmayer/VIIRS_Filter
.github/workflows/update-viirs.yml
ref: main
```

Der Worker benötigt dafür einen GitHub-Token mit möglichst eng begrenzten
Rechten auf dieses Repository.

Der öffentliche `workers.dev`-Endpunkt des Workers wird für den Cron Trigger
nicht benötigt. Der Worker kann ausschließlich über seinen `scheduled()`-
Handler betrieben werden.

## GitHub Actions Workflow

Der Produktionsworkflow arbeitet als:

```text
R2 -> GitHub Actions -> R2
```

Wichtige Eigenschaften:

- kein GitHub-Pages-Deployment,
- kein Speichern der großen GeoJSON-Datei im Repository,
- serieller Workflow über `concurrency`,
- Validierung des bestehenden und neu erzeugten GeoJSON,
- R2 als einzige persistente Datenquelle,
- stündliche externe Auslösung über Cloudflare.

Der Workflow erwartet, dass `viirs_vegetation.geojson` bereits im R2-Bucket
existiert. Fehlt die Datei, schlägt der Produktionsworkflow bewusst fehl,
anstatt unbemerkt mit einem leeren Datensatz neu zu beginnen.

## Statusdatei

Zusätzlich wird

```text
status.json
```

veröffentlicht.

Sie enthält unter anderem:

- Zeitpunkt der letzten erfolgreichen Erzeugung,
- Anzahl der Features,
- Größe der GeoJSON-Datei,
- Länge des rollenden Zeitfensters,
- abgefragtes VIIRS-Quellalter,
- Anzahl neuer Kandidaten,
- Anzahl nach dem Filter übernommener neuer Punkte.

Damit kann der Zustand der Pipeline geprüft werden, ohne die vollständige
GeoJSON-Datei herunterzuladen.

## ArcGIS Map Viewer und Dashboard

Der öffentliche R2-Link wird in ArcGIS Map Viewer als GeoJSON-Layer hinzugefügt:

```text
https://pub-<cloudflare-id>.r2.dev/viirs_vegetation.geojson
```

Danach kann die Web Map in einem ArcGIS Dashboard verwendet werden.

Wichtig: ArcGIS speichert die beim Hinzufügen erkannte Feldstruktur teilweise in
der Web Map. Wenn Felder später hinzugefügt oder entfernt werden, sollte der
GeoJSON-Layer in Map Viewer entfernt und neu hinzugefügt werden, damit das
Schema neu erkannt wird.

Der aktuelle öffentliche Datensatz ist bewusst klein gehalten, da ein
GeoJSON-Layer beim Laden als Datei übertragen wird und kein serverseitig
abfragbarer Feature Service ist.

## Lokaler Start

Benötigt werden:

- R,
- `curl`,
- `jsonlite`,
- `terra`.

Tests:

```bash
Rscript tests/test_helpers.R
```

Ein lokaler Lauf mit derselben 7-Tage-Konfiguration wie in Produktion kann zum
Beispiel so gestartet werden:

```bash
VIIRS_OUTPUT_PATH=site/viirs_vegetation.geojson \
ROLLING_WINDOW_HOURS=168 \
Rscript R/update_viirs.R
```

Ohne `VIIRS_OUTPUT_PATH` verwendet das R-Skript aus Kompatibilitätsgründen
weiterhin seinen internen Standardpfad.

## Konfiguration

Die wichtigsten Umgebungsvariablen:

| Variable | Produktion | Bedeutung |
|---|---:|---|
| `ROLLING_WINDOW_HOURS` | `168` | Länge des rollenden Ausgabefensters |
| `SOURCE_OVERLAP_HOURS` | `1` | zusätzliche Quell-Altersblöcke gegen Lücken |
| `BOOTSTRAP_HOURS` | `0` | optionaler Rückblick bei leerem Zustand |
| `LANDCOVER_GRID_SIZE` | `3` | `1` = Mittelpunkt, `3` = 3x3-Footprint |
| `VEGETATION_SHARE_THRESHOLD` | `0.5` | Mindestanteil Vegetation |
| `REJECT_BUILT_CENTER` | `true` | Built-up im Mittelpunkt ausschließen |
| `VEGETATION_CODES` | `10,20,30,40,90,95,100` | erlaubte WorldCover-Klassen |
| `VIIRS_CONFIDENCE` | `nominal,high` | erlaubte VIIRS-Confidence-Werte |
| `VIIRS_OUTPUT_PATH` | `site/viirs_vegetation.geojson` im Workflow | Ausgabedatei |
| `COUNTRY_BOUNDARIES_PATH` | `data/ne_50m_admin_0_countries.geojson` | Länderpolygone |

## Repository-Struktur

```text
.github/workflows/update-viirs.yml   Produktionsworkflow
R/update_viirs.R                     Datenabruf und Verarbeitung
R/lib_viirs.R                        Hilfsfunktionen
data/ne_50m_admin_0_countries.geojson
                                     Natural-Earth-Länderpolygone
tests/test_helpers.R                 Tests für Hilfsfunktionen
README.md                            Projektdokumentation
```

Der Ordner `site/` wird nur während eines lokalen oder GitHub-Actions-Laufs
erzeugt und ist über `.gitignore` von der Git-Historie ausgeschlossen.

## Datenquellen

### VIIRS

VIIRS Thermal Hotspots and Fire Activity werden über einen öffentlichen
ArcGIS-Feature-Service abgefragt:

```text
Satellite_VIIRS_Thermal_Hotspots_and_Fire_Activity
```

Das Skript verwendet den Service direkt über dessen ArcGIS REST API.

### ESA WorldCover

Landbedeckung:

```text
ESA WorldCover 2021 v200
```

Die benötigten COG-Kacheln werden direkt per HTTP gelesen.

### Natural Earth

Für die Länderzuordnung wird ein lokaler Natural-Earth-Admin-0-Datensatz mit
50-m-Auflösung verwendet.

## Grenzen und Hinweise

- VIIRS-Hotspots sind Thermal-Anomalien und nicht automatisch bestätigte
  Vegetationsbrände.
- Der WorldCover-Filter reduziert viele nichtvegetative Wärmequellen, kann
  Fehlklassifikationen aber nicht vollständig ausschließen.
- Der 3x3-Footprint ist eine Annäherung. Die exakte Orientierung des
  Satellitenpixels entlang der Flugbahn ist nicht verfügbar.
- Ländergrenzen folgen der verwendeten Natural-Earth-Geometrie und deren
  `SOVEREIGNT`-Definition.
- Punkte auf oder sehr nahe an Grenzen können von der verwendeten
  Polygongeometrie beeinflusst werden.
- Das System ist ein rollender Datensatz und kein Langzeitarchiv.
- R2 enthält nur den aktuellen Stand der Datei; historische Versionen werden
  nicht separat archiviert.
- Bei Änderungen am veröffentlichten GeoJSON-Schema muss der ArcGIS-Layer
  gegebenenfalls neu hinzugefügt werden.
- Bei stark wachsender Dateigröße sollte die Ladezeit im öffentlichen Dashboard
  regelmäßig geprüft werden.

## Betrieb prüfen

Für einen schnellen Funktionstest:

1. Prüfen, ob der Cloudflare Cron Trigger stündlich ausgeführt wird.
2. In GitHub Actions prüfen, ob `Update filtered VIIRS hotspots` erfolgreich
   läuft.
3. `status.json` prüfen und den Zeitstempel `generated_at` kontrollieren.
4. Die öffentliche `viirs_vegetation.geojson` direkt öffnen.
5. Im ArcGIS Dashboard kontrollieren, ob neue Punkte und `hours_old` aktualisiert
   werden.

Ein Fehler in einem Workflow-Lauf überschreibt den vorhandenen R2-Datensatz
nicht; die zuletzt erfolgreich veröffentlichte Datei bleibt verfügbar.
