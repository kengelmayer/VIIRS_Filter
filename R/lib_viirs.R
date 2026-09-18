`%||%` <- function(x, fallback) {
  if (is.null(x) || length(x) == 0L) fallback else x
}

env_integer <- function(name, default, minimum = -Inf, maximum = Inf) {
  raw <- Sys.getenv(name, unset = "")
  value <- if (nzchar(raw)) suppressWarnings(as.integer(raw)) else as.integer(default)
  if (is.na(value) || value < minimum || value > maximum) {
    stop(sprintf("%s must be an integer between %s and %s", name, minimum, maximum))
  }
  value
}

env_number <- function(name, default, minimum = -Inf, maximum = Inf) {
  raw <- Sys.getenv(name, unset = "")
  value <- if (nzchar(raw)) suppressWarnings(as.numeric(raw)) else as.numeric(default)
  if (is.na(value) || value < minimum || value > maximum) {
    stop(sprintf("%s must be a number between %s and %s", name, minimum, maximum))
  }
  value
}

env_flag <- function(name, default = FALSE) {
  raw <- tolower(Sys.getenv(name, unset = if (default) "true" else "false"))
  if (!raw %in% c("true", "false", "1", "0", "yes", "no")) {
    stop(sprintf("%s must be true or false", name))
  }
  raw %in% c("true", "1", "yes")
}

epoch_ms_to_iso <- function(value) {
  format(
    as.POSIXct(as.numeric(value) / 1000, origin = "1970-01-01", tz = "UTC"),
    "%Y-%m-%dT%H:%M:%SZ",
    tz = "UTC"
  )
}

make_detection_id <- function(satellite, acq_time_ms, longitude, latitude) {
  paste(
    satellite,
    sprintf("%.0f", as.numeric(acq_time_ms)),
    sprintf("%.5f", as.numeric(longitude)),
    sprintf("%.5f", as.numeric(latitude)),
    sep = "|"
  )
}

worldcover_tile_id <- function(longitude, latitude) {
  longitude <- pmin(pmax(as.numeric(longitude), -180), 180 - 1e-10)
  latitude <- pmin(pmax(as.numeric(latitude), -90), 90 - 1e-10)

  tile_lon <- floor(longitude / 3) * 3
  tile_lat <- floor(latitude / 3) * 3

  lat_prefix <- ifelse(tile_lat < 0, "S", "N")
  lon_prefix <- ifelse(tile_lon < 0, "W", "E")

  paste0(
    lat_prefix,
    sprintf("%02d", abs(as.integer(tile_lat))),
    lon_prefix,
    sprintf("%03d", abs(as.integer(tile_lon)))
  )
}

worldcover_tile_url <- function(tile_id) {
  paste0(
    "https://esa-worldcover.s3.eu-central-1.amazonaws.com/",
    "v200/2021/map/ESA_WorldCover_10m_2021_v200_",
    tile_id,
    "_Map.tif"
  )
}

worldcover_class_name <- function(code) {
  labels <- c(
    `10` = "Tree cover",
    `20` = "Shrubland",
    `30` = "Grassland",
    `40` = "Cropland",
    `50` = "Built-up",
    `60` = "Bare or sparse vegetation",
    `70` = "Snow and ice",
    `80` = "Permanent water bodies",
    `90` = "Herbaceous wetland",
    `95` = "Mangroves",
    `100` = "Moss and lichen"
  )
  result <- unname(labels[as.character(code)])
  result[is.na(result)] <- "Unknown"
  result
}

make_footprint_samples <- function(detections, grid_size = 3L) {
  if (!grid_size %in% c(1L, 3L)) {
    stop("LANDCOVER_GRID_SIZE must be 1 or 3")
  }
  if (nrow(detections) == 0L) {
    return(data.frame())
  }

  fractions <- if (grid_size == 1L) 0 else c(-1 / 3, 0, 1 / 3)
  grid <- expand.grid(fx = fractions, fy = fractions, KEEP.OUT.ATTRS = FALSE)
  sample_count <- nrow(grid)
  detection_row <- rep(seq_len(nrow(detections)), each = sample_count)
  fx <- rep(grid$fx, times = nrow(detections))
  fy <- rep(grid$fy, times = nrow(detections))
  latitude <- detections$latitude[detection_row]
  longitude <- detections$longitude[detection_row]
  scan_m <- detections$scan_km[detection_row] * 1000
  track_m <- detections$track_km[detection_row] * 1000
  scan_m[is.na(scan_m)] <- 375
  track_m[is.na(track_m)] <- 375
  cos_lat <- pmax(abs(cos(latitude * pi / 180)), 0.01)

  sample_lon <- longitude + (fx * scan_m) / (111320 * cos_lat)
  sample_lat <- latitude + (fy * track_m) / 111320
  sample_lon <- ((sample_lon + 180) %% 360) - 180

  samples <- data.frame(
    detection_row = detection_row,
    sample_index = rep(seq_len(sample_count), times = nrow(detections)),
    is_center = fx == 0 & fy == 0,
    longitude = sample_lon,
    latitude = sample_lat,
    stringsAsFactors = FALSE
  )
  samples$tile_id <- worldcover_tile_id(samples$longitude, samples$latitude)
  samples$landcover_code <- NA_integer_
  samples
}

prune_to_rolling_window <- function(detections, now_utc, window_hours) {
  if (nrow(detections) == 0L) {
    return(detections)
  }
  now_ms <- as.numeric(now_utc) * 1000
  age_hours <- (now_ms - as.numeric(detections$acq_time_ms)) / 3600000
  detections[!is.na(age_hours) & age_hours >= -1 & age_hours <= window_hours, , drop = FALSE]
}

empty_detection_frame <- function() {
  data.frame(
    detection_id = character(),
    longitude = numeric(),
    latitude = numeric(),
    acq_time_ms = numeric(),
    acq_time = character(),
    satellite = character(),
    confidence = character(),
    frp = numeric(),
    daynight = character(),
    scan_km = numeric(),
    track_km = numeric(),
    source_hours_old_at_ingest = integer(),
    landcover_center_code = integer(),
    landcover_center_class = character(),
    vegetation_share = numeric(),
    landcover_samples = integer(),
    stringsAsFactors = FALSE
  )
}
