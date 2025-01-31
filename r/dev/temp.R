# integrated water temperature dataset (aktemp + nps + usgs)

library(tidyverse)
library(janitor)
library(jsonlite)
library(glue)
library(sf)
library(terra)
library(httr2)

# load --------------------------------------------------------------------

aktemp <- read_rds("data/aktemp.rds")
usgs <- read_rds("data/usgs.rds")
nps <- read_rds("data/nps.rds")

datasets <- bind_rows(
  AKTEMP = aktemp,
  USGS = usgs,
  NPS = nps,
  .id = "dataset"
)

wbd <- read_rds("data/wbd.rds")

# stations ----------------------------------------------------------------

stn <- datasets |> 
  select(-data)

stn_sf <- stn |>
  st_as_sf(coords = c("longitude", "latitude"), crs = 4326)

tabyl(stn, dataset)
stn_sf |>
  mapview::mapview(zcol = "dataset", layer.name = "data source")


# basins ------------------------------------------------------------------

stn_wbd <- stn_sf |> 
  st_join(
    wbd$huc4 |> 
      select(huc4)
  ) |> 
  st_join(
    wbd$huc6 |> 
      select(huc6)
  ) |> 
  st_join(
    wbd$huc8 |> 
      select(huc8)
  ) |> 
  st_drop_geometry() |> 
  select(dataset, station_id, huc4, huc6, huc8)

# daily data --------------------------------------------------------------

temp_data <- datasets |> 
  select(dataset, station_id, data) |>
  rowwise() |> 
  mutate(
    n_values = nrow(data),
    start_date = min(data$date),
    end_date = max(data$date)
  )

temp_data |> 
  select(dataset, station_id, data) |> 
  unnest(data) |> 
  ggplot(aes(ymd(20001231) + days(yday(date)), mean_temp_c)) +
  geom_hex(bins = 100) +
  geom_hline(yintercept = 0) +
  scale_fill_viridis_c("# daily\nvalues", trans = "log10") +
  scale_x_date(date_labels = "%b %d", expand = expansion()) +
  labs(x = "day of year", y = "daily mean temp (C)") +
  facet_wrap(vars(dataset), ncol = 3) +
  theme_bw()

temp_data |> 
  select(dataset, station_id, data) |> 
  unnest(data) |> 
  count(dataset, yday = yday(date)) |> 
  ggplot(aes(ymd(20001231) + days(yday))) +
  geom_line(aes(y = n, color = dataset)) +
  scale_x_date(date_breaks = "2 months", date_labels = "%b %d", expand = expansion()) +
  scale_color_brewer(palette = "Set1") +
  labs(x = "day of year", y = "# daily values") +
  theme_bw()

temp_data |> 
  select(dataset, station_id, data) |> 
  unnest(data) |> 
  count(dataset, year = year(date)) |> 
  complete(dataset, year) |> 
  ggplot(aes(year)) +
  geom_col(aes(y = n, fill = dataset), width = 0.9, alpha = 0.75, position = position_dodge()) +
  scale_fill_brewer(palette = "Set1") +
  scale_x_continuous(expand = expansion(), breaks = scales::pretty_breaks(n = 10)) +
  labs(x = "year", y = "# daily values") +
  theme_bw()

temp_data |> 
  ggplot(aes(n_values)) +
  geom_histogram()

temp_data |> 
  arrange(n_values) |> 
  select(-data) |> 
  view()


# filter by seasonal criteria ---------------------------------------------
# group by station, year
#   calculate % of days between June 1 and Sep 30 with data

# MIN_FRAC_SUMMER <- 0.75
max_n_summer <- length(seq.Date(ymd(20010601), ymd(20010930), by = 1))

temp_data_year <- temp_data |> 
  ungroup() |> 
  select(dataset, station_id, data) |> 
  unnest(data) |> 
  mutate(year = year(date)) |> 
  nest_by(dataset, station_id, year) |> 
  mutate(
    n_summer = sum(between(month(data$date), 6, 9)),
    frac_summer = n_summer / max_n_summer
  ) |>
  filter(frac_summer > 0) |> 
  ungroup() |> 
  print()

temp_data_year |> 
  ggplot(aes(frac_summer)) +
  stat_ecdf()


# daymet ------------------------------------------------------------------

daymet_stn_year <- stn |>
  select(dataset, station_id, latitude, longitude) |> 
  semi_join(temp_data_year, by = c("dataset", "station_id")) |> 
  st_as_sf(coords = c("longitude", "latitude"), crs = 4326) |> 
  st_join(
    daymetr::tile_outlines |> 
      select(TileID)
  ) |> 
  st_drop_geometry() |> 
  clean_names() |> 
  inner_join(
    temp_data_year |> 
      distinct(dataset, station_id, year),
    by = c("dataset", "station_id")
  ) |> 
  filter(year < 2024)

daymet_tile_year <- daymet_stn_year |> 
  distinct(tile_id, year) |> 
  arrange(tile_id, year) |> 
  print()

download_daymet_tile <- function (tile_id, year, param, force = FALSE, timeout = 30) {
  cat("download_daymet_tile:", tile_id, year, param, "\n")
  f <- glue("data/daymet/{param}_{year}_{tile_id}.nc")
  url <- glue("https://thredds.daac.ornl.gov/thredds/fileServer/ornldaac/2129/tiles/{year}/{tile_id}_{year}/{param}.nc")
  
  if (file.exists(f) & file.size(f) == 0) {
    cat("deleting empty file:", f, "\n")
    unlink(f)
  }
  
  if (!file.exists(f) | force) {
    request(url) |> 
      req_retry(max_tries = 5) |> 
      req_timeout(timeout) |>
      req_perform(path = f)
    cat("saved:", f, "\n")
  } else {
    message("file already exists, use `force = TRUE` to overwrite (", f, ")")
  }
  f
}
possibly_download_daymet_tile <- possibly(download_daymet_tile, otherwise = "error")

daymet_tile_year |> 
  crossing(param = c("tmin", "tmax")) |> 
  rowwise() |> 
  mutate(
    filename = possibly_download_daymet_tile(tile_id, year, param)
  )

# convert nc to tif
daymetr::nc2tif("/mnt/data/ecosheds/aktempviz/daymet/")

# tif_file <- "data/daymet/tmax_2002_13330.tif"
# r <- terra::rast(tif_file)
# terra::project(r, "+proj=longlat +datum=WGS84")$tmax_1 |> 
#   plot()

param <- "tmax"
tile_id <- 13330
year <- 2004
latitude <- 59.5
longitude <- -161

extract_values_from_tile <- function (param, tile_id, year, latitude, longitude, path = "data/daymet") {
  tif_file <- file.path(path, glue("{param}_{year}_{tile_id}.tif"))
  r <- terra::rast(tif_file)
  point <- terra::vect(cbind(longitude, latitude), crs = "EPSG:4326")
  values <- terra::extract(r, terra::project(point, r))
  
  x <- tibble(
    param = param,
    date = terra::time(r),
    value = as.numeric(values)[2:length(values)]
  )
  
  if (day(last(x$date)) == 30) {
    x <- x |> 
      add_row(param = param, date = last(x$date) + days(1), value = last(x$value))
  }
  x
}
extract_values_from_tile(param, tile_id, year, latitude, longitude)

extract_daymet <- function (tile_id, year, latitude, longitude) {
  tmin <- extract_values_from_tile("tmin", tile_id, year, latitude, longitude)
  tmax <- extract_values_from_tile("tmax", tile_id, year, latitude, longitude)
  bind_rows(
    tmin,
    tmax
  ) |> 
    pivot_wider(names_from = "param") |> 
    mutate(tmean = (tmin + tmax) / 2) |> 
    rename(min_airtemp_c = tmin, max_airtemp_c = tmax, mean_airtemp_c = tmean)
}
possibly_extract_daymet <- possibly(extract_daymet, otherwise = NULL)

daymet_stn_year_data <- daymet_stn_year |>
  left_join(
    stn |>
      select(dataset, station_id, latitude, longitude),
    by = c("dataset", "station_id")
  ) |>
  mutate(
    daymet = pmap(list(tile_id, year, latitude, longitude), possibly_extract_daymet, .progress = TRUE)
  )
daymet_stn_year_data |>
  write_rds("data/daymet_stn_year_data.rds")
daymet_stn_year_data <- read_rds("data/daymet_stn_year_data.rds")

# re-download tiles that failed
# daymet_stn_year_data |>
#   mutate(
#     error = map_lgl(daymet, is.null)
#   ) |>
#   filter(error) |>
#   distinct(tile_id, year) |>
#   rowwise() |>
#   mutate(
#     filename = list({
#       unlink(file.path("data/daymet", glue("tmax_{year}_{tile_id}.tif")))
#       unlink(file.path("data/daymet", glue("tmax_{year}_{tile_id}.tif.aux.json")))
#       unlink(file.path("data/daymet", glue("tmin_{year}_{tile_id}.tif")))
#       unlink(file.path("data/daymet", glue("tmin_{year}_{tile_id}.tif.aux.json")))
#       possibly_download_daymet_tile(tile_id, year, "tmin", force = TRUE)
#       possibly_download_daymet_tile(tile_id, year, "tmax", force = TRUE)
#     })
#   )

daymet_stn_year_data |> 
  select(dataset, station_id, daymet) |>
  unnest(daymet) |> 
  pivot_longer(ends_with("_c")) |> 
  ggplot(aes(yday(date), value)) +
  geom_hex(bins = 100) +
  facet_wrap(vars(name), scales = "free_y", ncol = 1)


# download: single pixel (too slow) ---------------------------------------

# daymet_stn <- stn |>
#   select(dataset, station_id, latitude, longitude) |> 
#   inner_join(
#     temp_data_summer |> 
#       group_by(station_id) |> 
#       summarise(
#         start_year = min(year),
#         end_year = max(year)
#       ),
#     by = "station_id"
#   )

# download_daymet_data <- function (station_id, latitude, longitude, start_year, end_year, path = "data/daymet", force = FALSE) {
#   cat(glue("station_id: {station_id}, years: {start_year}-{end_year}"), "\n")
#   filename <- file.path(path, str_c(make_clean_names(station_id), "_", start_year, "_", end_year, ".rds"))
#   
#   if (file.exists(filename) && !force) {
#     message("file already exists, use `force = TRUE` to overwrite (", filename, ")")
#     return(filename)
#   }
#   
#   Sys.sleep(2)
# 
#   # direct via API
#   # https://daymet.ornl.gov/single-pixel/api/data?lat=43.1&lon=-85.3&vars=tmax,tmin&years=2012,2013
#   # url <- url_parse("https://daymet.ornl.gov/single-pixel/api/data")
#   # url$query <- list(
#   #   lat = latitude,
#   #   lon = longitude,
#   #   vars = "tmax,tmin",
#   #   years = year
#   # )
#   # x <- url_build(url) |> 
#   #   request() |> 
#   #   req_perform() |> 
#   #   resp_body_string()
#   
#   # using {daymetr}
#   x <- daymetr::download_daymet(
#     lat = latitude,
#     lon = longitude,
#     start = start_year,
#     end = end_year
#   )
#   
#   write_rds(x, filename)
#   
#   filename
# }

# daymetr::download_daymet(
#   lat = daymet_stn_yr$latitude[1],
#   lon = daymet_stn_yr$longitude[1],
#   start = 2020,
#   end = 2021,
#   path = "data/daymet"
# )

# daymet_raw <- daymet_stn_yr |> 
#   rowwise() |> 
#   mutate(
#     filename = pmap(list(station_id, latitude, longitude, start_year, end_year), download_daymet_data, .progress = TRUE)
#   )
# write_rds(daymet_raw, "data/daymet-raw.rds")


# merge -------------------------------------------------------------------

temp_data_year |> 
  tabyl(year, dataset) |>
  adorn_totals(where = "both") |> 
  knitr::kable()

temp <- temp_data_year |> 
  select(dataset, station_id, year, data) |> 
  left_join(
    daymet_stn_year_data |> 
      select(dataset, station_id, year, daymet),
    by = c("dataset", "station_id", "year")
  ) |> 
  rowwise() |> 
  mutate(
    data_day = list({
      x <- data |> 
        complete(date = seq.Date(min(date), max(date), by = "day")) 
      if (!is.null(daymet)) {
        x <- x |>
          left_join(
            daymet,
            by = "date"
          )
      } else {
        x <- x |> 
          mutate(
            min_airtemp_c = NA_real_,
            max_airtemp_c = NA_real_,
            mean_airtemp_c = NA_real_
          )
      }
      x
    })
    # data_week = list({
    #   data_day |> 
    #     select(date, mean_temp_c, mean_airtemp_c) |> 
    #     group_by(week = week(date)) |>
    #     summarise(
    #       n_days = n(),
    #       mean_temp_c = mean(mean_temp_c),
    #       mean_airtemp_c = mean(mean_airtemp_c),
    #       .groups = "drop"
    #     ) |>
    #     mutate(
    #       date = ymd(str_c(year, "0101")) + days(7 * (week - 1)),
    #       .before = everything()
    #     ) |>
    #     filter(n_days == 7, !is.na(mean_temp_c), !is.na(mean_airtemp_c)) |> 
    #     select(-n_days)
    # })
  ) |> 
  select(-data, -daymet) |> 
  print()

# temp |> 
#   select(-data_day) |> 
#   unnest(data_week) |> 
#   ggplot(aes(date, mean_temp_c)) +
#   geom_hex(bins = 100) +
#   scale_fill_viridis_c(trans = "log10") +
#   scale_x_date(date_breaks = "2 years", date_labels = "%Y") +
#   labs(x = "date", y = "weekly mean water temp (degC)") +
#   theme_bw()
# 
# temp |> 
#   select(-data_day) |> 
#   unnest(data_week) |> 
#   ggplot(aes(ymd(20001231) + days(yday(date)), mean_temp_c)) +
#   geom_hex(bins = 50) +
#   scale_x_date(date_labels = "%b %d") +
#   scale_fill_viridis_c("count", trans = "log10") +
#   labs(x = "day of year", y = "weekly mean water temp (degC)") +
#   theme_bw()
# 
# temp |> 
#   select(-data_day) |> 
#   unnest(data_week) |> 
#   filter(mean_airtemp_c > -10) |> 
#   ggplot(aes(mean_airtemp_c, mean_temp_c)) +
#   geom_hex(bins = 100) +
#   geom_hline(yintercept = 0, alpha = 0.5) +
#   geom_vline(xintercept = 0, alpha = 0.5) +
#   scale_fill_viridis_c("count", trans = "log10") +
#   labs(x = "weekly mean air temp (degC)", y = "weekly mean water temp (degC)") +
#   theme_bw()
# 
# temp_july <- temp |> 
#   select(-data_week) |> 
#   unnest(data_day) |> 
#   filter(month(date) == 7, !is.na(mean_temp_c)) |> 
#   group_by(station_id, year) |> 
#   summarise(
#     n = n(),
#     across(starts_with("mean_"), \(x) max(x, na.rm = TRUE), .names = "max_{.col}"),
#     across(starts_with("mean_"), \(x) mean(x, na.rm = TRUE), .names = "mean_{.col}"),
#     .groups = "drop"
#   ) |> 
#   filter(n == 31)
# 
# temp_july_7d <- temp |>
#   select(-data_week) |> 
#   unnest(data_day) |> 
#   filter(month(date) == 7, !is.na(mean_temp_c)) |> 
#   add_count(station_id, year, name = "n_day") |> 
#   filter(n_day == 31) |>
#   select(-n_day) |> 
#   arrange(station_id, date) |> 
#   group_by(station_id, year) |> 
#   mutate(
#     mean_temp_c_7d = slider::slide_dbl(mean_temp_c, mean, .before = 6, .after = 0, .complete = TRUE),
#     mean_airtemp_c_7d = slider::slide_dbl(mean_airtemp_c, mean, .before = 6, .after = 0, .complete = TRUE)
#   ) |> 
#   summarise(
#     max_temp_c_7d = max(mean_temp_c_7d, na.rm = TRUE),
#     max_airtemp_c_7d = max(mean_airtemp_c_7d, na.rm = TRUE),
#     mean_temp_c_7d = mean(mean_temp_c_7d, na.rm = TRUE),
#     mean_airtemp_c_7d = mean(mean_airtemp_c_7d, na.rm = TRUE)
#   )
# 
# temp_july |> 
#   select(station_id, year, airtemp_c = mean_mean_airtemp_c, temp_c = mean_mean_temp_c) |> 
#   add_count(station_id, name = "n_year") |> 
#   # filter(n_year >= 10) |>
#   pivot_longer(ends_with("_c")) |> 
#   group_by(station_id, name) |> 
#   mutate(
#     scaled = value - mean(value)
#   ) |> 
#   pivot_longer(c(value, scaled), names_to = "var") |>
#   mutate(var = factor(var, levels = c("value", "scaled"))) |> 
#   ggplot(aes(year, value)) +
#   geom_line(aes(group = station_id), alpha = 0.5) +
#   geom_point(size = 1, alpha = 0.5) +
#   facet_grid(vars(var), vars(name), scales = "free_y", switch = "y", labeller = labeller(
#     var = c(
#       value = "mean july",
#       scaled = "scaled mean july"
#     ),
#     name = c(
#       airtemp_c = "air temp (degC)",
#       temp_c = "water temp (degC)"
#     )
#   )) +
#   labs(y = NULL, title = "mean july temperatures", subtitle = "scaled = centered by station (subtract long-term mean)") +
#   theme_bw() +
#   theme(
#     strip.placement = "outside",
#     strip.background = element_blank()
#   )
# 
# temp_july |> 
#   arrange(station_id, year) |>
#   ggplot(aes(mean_mean_airtemp_c, mean_mean_temp_c)) +
#   geom_point(aes(color = year)) +
#   scale_color_viridis_c("year") +
#   labs(
#     x = "mean july air temp (degC)", y = "mean july water temp (degC)",
#     title = "mean july air vs water temperatures"
#   ) +
#   theme_bw()
# 
# temp_july_7d |> 
#   arrange(station_id, year) |>
#   ggplot(aes(max_airtemp_c_7d, max_temp_c_7d)) +
#   geom_point(aes(color = year)) +
#   scale_color_viridis_c("year") +
#   labs(
#     x = "max 7-day july air temp (degC)", y = "max 7-day july water temp (degC)",
#     title = "max 7-day july air vs water temperatures"
#   ) +
#   theme_bw()
# 
# state <- USAboundaries::us_states(states = "AK", resolution = "low") |> 
#   st_transform(crs = 3338)
# 
# temp_july_sf <- temp_july |> 
#   select(station_id, year, temp_c = mean_mean_temp_c) |> 
#   filter(year >= 2012) |> 
#   left_join(
#     stn |> 
#       select(station_id, latitude, longitude),
#     by = "station_id"
#   ) |> 
#   st_as_sf(coords = c("longitude", "latitude"), crs = 4326)
# 
# state |> 
#   ggplot() +
#   geom_sf(fill = NA) +
#   geom_sf(
#     data = temp_july_sf,
#     aes(color = temp_c), size = 2
#   ) +
#   scale_color_viridis_c("mean july\nwater temp\n(degC)") +
#   facet_wrap(vars(year), ncol = 3) +
#   theme_void()


# export ------------------------------------------------------------------

export_temp <- temp |> 
  unnest(data_day) |> 
  select(dataset, station_id, date, temp_c = mean_temp_c, airtemp_c = mean_airtemp_c) |>
  arrange(dataset, station_id, date) |> 
  nest_by(dataset, station_id) |>
  mutate(
    start = min(data$date),
    end = max(data$date),
    n = sum(!is.na(data$temp_c)),
    filename = {
      f <- toupper(glue("{dataset}_{snakecase::to_snake_case(station_id)}.json"))
      write_json(data, file.path("../public/data/stations", f))
      f
    }
  ) |>
  print()

export_stn <- stn |> 
  left_join(
    stn_wbd,
    by = c("dataset", "station_id")
  ) |> 
  inner_join(
    export_temp |> 
      select(-data),
    by = c("dataset", "station_id")
  )

export_stn |> 
  write_json("../public/data/stations.json", digits = 8)

list(
  daymet = list(
    last_year = 2023
  ),
  last_updated = format_ISO8601(now(tz = "UTC"), usetz = TRUE)
) |> 
  write_json("../public/data/config.json", auto_unbox = TRUE)
