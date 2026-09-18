source(file.path("R", "lib_viirs.R"))

stopifnot(
  worldcover_tile_id(13.405, 52.52) == "N51E012",
  worldcover_tile_id(-78.5, -0.2) == "S03W081",
  worldcover_tile_id(0, 0) == "N00E000"
)

id <- make_detection_id("N20", 1789687740000, 13.405001, 52.520001)
stopifnot(id == "N20|1789687740000|13.40500|52.52000")

input <- data.frame(
  latitude = 52.52,
  longitude = 13.405,
  scan_km = 0.6,
  track_km = 0.5
)
samples <- make_footprint_samples(input, grid_size = 3L)
stopifnot(nrow(samples) == 9L, sum(samples$is_center) == 1L)

now <- as.POSIXct("2026-09-18T12:00:00Z", tz = "UTC")
detections <- data.frame(
  acq_time_ms = c(
    as.numeric(now - 11 * 3600) * 1000,
    as.numeric(now - 13 * 3600) * 1000
  )
)
kept <- prune_to_rolling_window(detections, now, 12L)
stopifnot(nrow(kept) == 1L)

message("All helper tests passed")
