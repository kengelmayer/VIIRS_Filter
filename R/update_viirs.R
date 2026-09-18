#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE, timeout = 600)

required_packages <- c("curl", "jsonlite", "terra")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0L) {
  stop("Missing R packages: ", paste(missing_packages, collapse = ", "))
}

script_args <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", script_args, value = TRUE)
script_path <- if (length(file_arg)) sub("^--file=", "", file_arg[[1]]) else "R/update_viirs.R"
source(file.path(dirname(normalizePath(script_path)), "lib_viirs.R"))

VIIRS_QUERY_URL <- paste0(
  "https://services9.arcgis.com/RHVPKKiFTONKtxq3/arcgis/rest/services/",
  "Satellite_VIIRS_Thermal_Hotspots_and_Fire_Activity/FeatureServer/0/query"
)

output_path <- Sys.getenv(
  "VIIRS_OUTPUT_PATH",
  unset = file.path("site", "viirs_vegetation_24h.geojson")
)
status_path <- Sys.getenv(
  "VIIRS_STATUS_PATH",
  unset = file.path(dirname(output_path), "status.json")
)
rolling_hours <- env_integer("ROLLING_WINDOW_HOURS", 24L, minimum = 1L, maximum = 168L)
source_overlap <- env_integer("SOURCE_OVERLAP_HOURS", 1L, minimum = 0L, maximum = 12L)
bootstrap_hours <- env_integer("BOOTSTRAP_HOURS", 0L, minimum = 0L, maximum = 168L)
page_size <- env_integer("VIIRS_PAGE_SIZE", 16000L, minimum = 1L, maximum = 16000L)
grid_size <- env_integer("LANDCOVER_GRID_SIZE", 3L, minimum = 1L, maximum = 3L)
vegetation_threshold <- env_number("VEGETATION_SHARE_THRESHOLD", 0.5, minimum = 0, maximum = 1)
reject_built_center <- env_flag("REJECT_BUILT_CENTER", TRUE)

vegetation_codes <- strsplit(
  Sys.getenv("VEGETATION_CODES", unset = "10,20,30,40,90,95,100"),
  ",",
  fixed = TRUE
)[[1]]
vegetation_codes <- suppressWarnings(as.integer(trimws(vegetation_codes)))
if (anyNA(vegetation_codes)) {
  stop("VEGETATION_CODES must contain comma-separated integers")
}

confidence_values <- strsplit(
  Sys.getenv("VIIRS_CONFIDENCE", unset = "nominal,high"),
  ",",
  fixed = TRUE
)[[1]]
confidence_values <- trimws(confidence_values)
if (any(!grepl("^[A-Za-z]+$", confidence_values))) {
  stop("VIIRS_CONFIDENCE contains an invalid value")
}

now_override <- Sys.getenv("NOW_UTC", unset = "")
now_utc <- if (nzchar(now_override)) {
  as.POSIXct(now_override, tz = "UTC")
} else {
  as.POSIXct(Sys.time(), tz = "UTC")
}
if (is.na(now_utc)) {
  stop("NOW_UTC is not a valid timestamp")
}

message(sprintf("Run time: %s", format(now_utc, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")))

encode_query <- function(params) {
  paste(
    vapply(
      names(params),
      function(name) {
        paste0(
          curl::curl_escape(name),
          "=",
          curl::curl_escape(as.character(params[[name]]))
        )
      },
      character(1)
    ),
    collapse = "&"
  )
}

get_json <- function(url, params, attempts = 4L) {
  request_url <- paste0(url, "?", encode_query(params))
  last_error <- NULL

  for (attempt in seq_len(attempts)) {
    result <- tryCatch(
      {
        handle <- curl::new_handle(
          failonerror = FALSE,
          useragent = "VIIRS-vegetation-filter/1.0",
          connecttimeout = 30,
          timeout = 300
        )
        curl::curl_fetch_memory(request_url, handle = handle)
      },
      error = function(error) error
    )

    if (!inherits(result, "error") && result$status_code >= 200L && result$status_code < 300L) {
      parsed <- jsonlite::fromJSON(rawToChar(result$content), simplifyVector = FALSE)
      if (!is.null(parsed$error)) {
        stop("ArcGIS REST error: ", parsed$error$message %||% "unknown error")
      }
      return(parsed)
    }

    last_error <- if (inherits(result, "error")) {
      conditionMessage(result)
    } else {
      paste("HTTP", result$status_code)
    }
    if (attempt < attempts) {
      Sys.sleep(min(2^(attempt - 1L), 8))
    }
  }

  stop("Request failed after retries: ", last_error)
}

feature_property <- function(properties, name, default = NA) {
  value <- properties[[name]]
  if (is.null(value) || length(value) == 0L) default else value[[1]]
}

read_existing_geojson <- function(path) {
  if (!file.exists(path) || file.info(path)$size == 0) {
    return(empty_detection_frame())
  }

  document <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  features <- document$features %||% list()
  if (length(features) == 0L) {
    return(empty_detection_frame())
  }

  rows <- lapply(features, function(feature) {
    properties <- feature$properties %||% list()
    coordinates <- feature$geometry$coordinates %||% c(NA_real_, NA_real_)
    data.frame(
      detection_id = as.character(feature_property(properties, "detection_id", feature$id %||% "")),
      longitude = as.numeric(coordinates[[1]]),
      latitude = as.numeric(coordinates[[2]]),
      acq_time_ms = as.numeric(feature_property(properties, "acq_time_ms")),
      acq_time = as.character(feature_property(properties, "acq_time", "")),
      satellite = as.character(feature_property(properties, "satellite", "")),
      confidence = as.character(feature_property(properties, "confidence", "")),
      frp = as.numeric(feature_property(properties, "frp")),
      daynight = as.character(feature_property(properties, "daynight", "")),
      scan_km = as.numeric(feature_property(properties, "scan_km")),
      track_km = as.numeric(feature_property(properties, "track_km")),
      source_hours_old_at_ingest = as.integer(feature_property(properties, "source_hours_old_at_ingest")),
      landcover_center_code = as.integer(feature_property(properties, "landcover_center_code")),
      landcover_center_class = as.character(feature_property(properties, "landcover_center_class", "Unknown")),
      vegetation_share = as.numeric(feature_property(properties, "vegetation_share")),
      landcover_samples = as.integer(feature_property(properties, "landcover_samples")),
      stringsAsFactors = FALSE
    )
  })

  result <- do.call(rbind, rows)
  valid <- nzchar(result$detection_id) & !is.na(result$acq_time_ms)
  result[valid, , drop = FALSE]
}

get_minimum_source_age <- function() {
  statistics <- jsonlite::toJSON(
    list(list(
      statisticType = "min",
      onStatisticField = "hours_old",
      outStatisticFieldName = "min_age"
    )),
    auto_unbox = TRUE
  )
  response <- get_json(
    VIIRS_QUERY_URL,
    list(
      where = "1=1",
      outStatistics = statistics,
      returnGeometry = "false",
      f = "json"
    )
  )
  value <- response$features[[1]]$attributes$min_age %||% NULL
  if (is.null(value)) stop("The VIIRS service did not return a minimum hours_old value")
  as.integer(value)
}

arcgis_features_to_frame <- function(features) {
  if (length(features) == 0L) return(empty_detection_frame()[, 1:12, drop = FALSE])

  rows <- lapply(features, function(feature) {
    attributes <- feature$attributes %||% list()
    geometry <- feature$geometry %||% list()
    longitude <- as.numeric(geometry$x %||% attributes$longitude %||% NA_real_)
    latitude <- as.numeric(geometry$y %||% attributes$latitude %||% NA_real_)
    acq_time_ms <- as.numeric(attributes$acq_time %||% NA_real_)
    satellite <- as.character(attributes$satellite %||% "")

    data.frame(
      detection_id = make_detection_id(satellite, acq_time_ms, longitude, latitude),
      longitude = longitude,
      latitude = latitude,
      acq_time_ms = acq_time_ms,
      acq_time = epoch_ms_to_iso(acq_time_ms),
      satellite = satellite,
      confidence = as.character(attributes$confidence %||% ""),
      frp = as.numeric(attributes$frp %||% NA_real_),
      daynight = as.character(attributes$daynight %||% ""),
      scan_km = as.numeric(attributes$scan %||% NA_real_),
      track_km = as.numeric(attributes$track %||% NA_real_),
      source_hours_old_at_ingest = as.integer(attributes$hours_old %||% NA_integer_),
      stringsAsFactors = FALSE
    )
  })

  result <- do.call(rbind, rows)
  valid <- is.finite(result$longitude) & is.finite(result$latitude) & !is.na(result$acq_time_ms)
  result[valid, , drop = FALSE]
}

query_viirs <- function(maximum_source_age) {
  confidence_sql <- paste(sprintf("'%s'", confidence_values), collapse = ",")
  where <- sprintf(
    "hours_old <= %d AND confidence IN (%s)",
    maximum_source_age,
    confidence_sql
  )
  fields <- paste(
    c(
      "OBJECTID", "latitude", "longitude", "acq_time", "satellite",
      "confidence", "frp", "daynight", "scan", "track", "hours_old"
    ),
    collapse = ","
  )

  offset <- 0L
  all_features <- list()
  repeat {
    response <- get_json(
      VIIRS_QUERY_URL,
      list(
        where = where,
        outFields = fields,
        returnGeometry = "true",
        outSR = "4326",
        orderByFields = "OBJECTID ASC",
        resultOffset = offset,
        resultRecordCount = page_size,
        f = "json"
      )
    )
    page <- response$features %||% list()
    all_features <- c(all_features, page)
    message(sprintf("Downloaded %d VIIRS records", length(all_features)))

    if (length(page) == 0L || !isTRUE(response$exceededTransferLimit)) break
    offset <- offset + length(page)
  }

  arcgis_features_to_frame(all_features)
}

probe_cog <- function(url) {
  handle <- curl::new_handle(
    nobody = TRUE,
    failonerror = FALSE,
    useragent = "VIIRS-vegetation-filter/1.0",
    connecttimeout = 30,
    timeout = 120
  )
  response <- curl::curl_fetch_memory(url, handle = handle)
  if (response$status_code == 200L) return(TRUE)
  if (response$status_code == 404L) return(FALSE)
  stop("Unexpected WorldCover response for ", url, ": HTTP ", response$status_code)
}

sample_worldcover <- function(detections) {
  if (nrow(detections) == 0L) {
    detections$landcover_center_code <- integer()
    detections$landcover_center_class <- character()
    detections$vegetation_share <- numeric()
    detections$landcover_samples <- integer()
    return(detections)
  }

  Sys.setenv(
    AWS_NO_SIGN_REQUEST = "YES",
    GDAL_HTTP_MULTIRANGE = "YES",
    GDAL_HTTP_MERGE_CONSECUTIVE_RANGES = "YES",
    GDAL_HTTP_MAX_RETRY = "3",
    GDAL_HTTP_RETRY_DELAY = "1",
    CPL_VSIL_CURL_CACHE_SIZE = "67108864",
    VSI_CACHE = "TRUE",
    VSI_CACHE_SIZE = "67108864"
  )

  samples <- make_footprint_samples(detections, grid_size = grid_size)
  tile_groups <- split(seq_len(nrow(samples)), samples$tile_id)
  tile_names <- names(tile_groups)
  message(sprintf(
    "Sampling %d footprint positions from %d WorldCover tiles",
    nrow(samples),
    length(tile_groups)
  ))

  for (tile_number in seq_along(tile_groups)) {
    indices <- tile_groups[[tile_number]]
    tile_id <- tile_names[[tile_number]]
    tile_url <- worldcover_tile_url(tile_id)

    if (probe_cog(tile_url)) {
      raster <- tryCatch(
        terra::rast(paste0("/vsicurl/", tile_url)),
        error = function(error) {
          stop("Could not open WorldCover tile ", tile_id, ": ", conditionMessage(error))
        }
      )
      coordinates <- as.matrix(samples[indices, c("longitude", "latitude")])
      extracted <- tryCatch(
        terra::extract(raster, coordinates),
        error = function(error) {
          stop("Could not sample WorldCover tile ", tile_id, ": ", conditionMessage(error))
        }
      )
      samples$landcover_code[indices] <- as.integer(extracted[[1]])
    }

    if (tile_number %% 25L == 0L || tile_number == length(tile_groups)) {
      message(sprintf("Processed WorldCover tile %d/%d", tile_number, length(tile_groups)))
    }
  }

  center_code <- rep(NA_integer_, nrow(detections))
  center_rows <- samples$is_center
  center_code[samples$detection_row[center_rows]] <- samples$landcover_code[center_rows]

  valid <- !is.na(samples$landcover_code)
  vegetation <- valid & samples$landcover_code %in% vegetation_codes
  valid_samples <- tabulate(samples$detection_row[valid], nbins = nrow(detections))
  vegetation_samples <- tabulate(samples$detection_row[vegetation], nbins = nrow(detections))
  vegetation_share <- ifelse(valid_samples > 0L, vegetation_samples / valid_samples, NA_real_)

  detections$landcover_center_code <- center_code
  detections$landcover_center_class <- worldcover_class_name(center_code)
  detections$vegetation_share <- round(vegetation_share, 3)
  detections$landcover_samples <- valid_samples

  keep <- valid_samples > 0L & vegetation_share >= vegetation_threshold
  if (reject_built_center) {
    keep <- keep & (is.na(center_code) | center_code != 50L)
  }

  message(sprintf(
    "WorldCover retained %d/%d new detections",
    sum(keep, na.rm = TRUE),
    nrow(detections)
  ))
  detections[keep, , drop = FALSE]
}

frame_to_feature_collection <- function(detections) {
  if (nrow(detections) > 0L) {
    detections <- detections[order(detections$acq_time_ms, detections$detection_id), , drop = FALSE]
  }

  features <- lapply(seq_len(nrow(detections)), function(i) {
    row <- detections[i, , drop = FALSE]
    list(
      type = "Feature",
      id = row$detection_id[[1]],
      geometry = list(
        type = "Point",
        coordinates = unname(c(row$longitude[[1]], row$latitude[[1]]))
      ),
      properties = list(
        detection_id = row$detection_id[[1]],
        acq_time = row$acq_time[[1]],
        acq_time_ms = row$acq_time_ms[[1]],
        satellite = row$satellite[[1]],
        confidence = row$confidence[[1]],
        frp = row$frp[[1]],
        daynight = row$daynight[[1]],
        scan_km = row$scan_km[[1]],
        track_km = row$track_km[[1]],
        source_hours_old_at_ingest = row$source_hours_old_at_ingest[[1]],
        landcover_center_code = row$landcover_center_code[[1]],
        landcover_center_class = row$landcover_center_class[[1]],
        vegetation_share = row$vegetation_share[[1]],
        landcover_samples = row$landcover_samples[[1]]
      )
    )
  })

  list(
    type = "FeatureCollection",
    name = sprintf("VIIRS vegetation hotspots - rolling %d hours", rolling_hours),
    generated_at = format(now_utc, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    features = features
  )
}

write_json_atomic <- function(document, path) {
  directory <- dirname(path)
  dir.create(directory, recursive = TRUE, showWarnings = FALSE)
  temporary_path <- tempfile(pattern = "viirs-", tmpdir = directory, fileext = ".geojson")
  on.exit(unlink(temporary_path), add = TRUE)
  jsonlite::write_json(
    document,
    temporary_path,
    auto_unbox = TRUE,
    pretty = FALSE,
    digits = 10,
    na = "null",
    null = "null"
  )
  if (!file.rename(temporary_path, path)) {
    if (!file.copy(temporary_path, path, overwrite = TRUE)) {
      stop("Could not replace output file: ", path)
    }
  }
}

existing <- read_existing_geojson(output_path)
existing <- prune_to_rolling_window(existing, now_utc, rolling_hours)
message(sprintf("Existing detections within rolling window: %d", nrow(existing)))

minimum_source_age <- get_minimum_source_age()
maximum_source_age <- minimum_source_age + source_overlap
if (nrow(existing) == 0L && bootstrap_hours > 0L) {
  maximum_source_age <- max(maximum_source_age, bootstrap_hours)
  message(sprintf("Empty output: optional bootstrap through source age %d", maximum_source_age))
}
message(sprintf(
  "Newest source age is %d; querying hours_old <= %d",
  minimum_source_age,
  maximum_source_age
))

new_detections <- query_viirs(maximum_source_age)
new_detections <- prune_to_rolling_window(new_detections, now_utc, rolling_hours)
new_detections <- new_detections[
  !duplicated(new_detections$detection_id) & !new_detections$detection_id %in% existing$detection_id,
  ,
  drop = FALSE
]
message(sprintf("Previously unseen detections in rolling window: %d", nrow(new_detections)))

new_candidate_count <- nrow(new_detections)
new_detections <- sample_worldcover(new_detections)
new_retained_count <- nrow(new_detections)
combined <- rbind(existing, new_detections)
combined <- combined[!duplicated(combined$detection_id, fromLast = TRUE), , drop = FALSE]
combined <- prune_to_rolling_window(combined, now_utc, rolling_hours)

write_json_atomic(frame_to_feature_collection(combined), output_path)
output_bytes <- file.info(output_path)$size
write_json_atomic(
  list(
    generated_at = format(now_utc, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    feature_count = nrow(combined),
    rolling_window_hours = rolling_hours,
    geojson_size_bytes = unname(output_bytes),
    source_minimum_age = minimum_source_age,
    source_maximum_age_queried = maximum_source_age,
    new_candidates = new_candidate_count,
    new_retained = new_retained_count
  ),
  status_path
)
message(sprintf("Wrote %d detections to %s", nrow(combined), output_path))
