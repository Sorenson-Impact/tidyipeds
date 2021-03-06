# This function checks if an index update is needed, and then downloads the specified files and helpfiles.

download_ipeds <- function(survey, years = NULL) {

  pkg_path <- system.file(package = "tidyipeds")

  if(!fs::dir_exists(fs::path(pkg_path, "ipeds_data"))) fs::dir_create(fs::path(pkg_path, "ipeds_data"))

  if(!fs::dir_exists(fs::path(pkg_path, "ipeds_data", "uncleaned"))) fs::dir_create(fs::path(pkg_path, "ipeds_data", "uncleaned"))

  if(!fs::dir_exists(fs::path(pkg_path, "ipeds_data", "helpfiles"))) fs::dir_create(fs::path(pkg_path, "ipeds_data", "helpfiles"))

  ipeds_path <- fs::path(pkg_path, "ipeds_data")

  update_available_ipeds() #This checks if an update is needed, then calls the scrape function if so.

  ipeds <- readr::read_rds(fs::path(ipeds_path, "datacenter_scrape.rds"))


  ipeds <- ipeds %>%
  dplyr::mutate(survgroup = stringr::str_remove(data_file, as.character(year)) %>%
    stringr::str_remove(year_to_fiscal(year))) %>%
  dplyr::mutate(survgroup = dplyr::case_when(
    stringr::str_detect(data_file, "GR200_") ~ "GR200",
    TRUE ~ survgroup
  )) %>%
    dplyr::mutate(survgroup = stringr::str_to_lower(survgroup))

  if(!is.null(years)) {
    ipeds <- ipeds %>%
      dplyr::filter(year %in% years)
  }

  ipeds %>%
    dplyr::filter(survgroup == !!survey) %>%
    split(.$data_file) %>%
    purrr::walk(function(ip) {

      temp <- fs::path(tempdir(), "ipeds", ip$data_file)

      fs::dir_create(temp)

      cat("\n", crayon::magenta(crayon::bgWhite(ip$data_file)), "\n")


      tempdata <- paste0(temp, "/data.zip")
      temphelp <- paste0(temp, "/help.zip")

      while(!fs::file_exists(tempdata)) {
        tryCatch(utils::download.file(ip$data_url, tempdata, mode = "wb"), error = function(e) {
          cat(crayon::white(crayon::bgRed("Error, retrying download...\n")))
          message(e)
          fs::file_delete(fs::dir_ls(temp))
        })
      }

      utils::unzip(tempdata, exdir = temp)

      is_provisional = !any(fs::dir_ls(temp) %>% stringr::str_detect("_rv|_RV")) #_rv means it's revised, ie final

      file <- if(!is_provisional) fs::dir_ls(temp, glob = "*_rv.csv|*_RV.csv") else fs::dir_ls(temp, glob = "*.csv")

      if(stringr::str_detect(stringr::str_to_lower(basename(file)), "^hd")) {
        csv <- suppressMessages(readr::read_delim(file, delim = ",", escape_double = F, trim_ws = T, guess_max = 10000, na = c("", "NA", ".")))
      } else {
        csv <- suppressMessages(readr::read_csv(file, guess_max = 10000, na = c("", "NA", ".")))
      }

      rds_name <- file %>%
        basename() %>%
        stringr::str_remove_all("_rv|_RV") %>%
        stringr::str_replace(".csv", ".rds")

      cat("\n", crayon::red("Writing compressed file:", rds_name, "\n"))

      csv %>% readr::write_rds(fs::path(ipeds_path, "uncleaned", rds_name), compress = "gz")

      cat("\n", crayon::green("Adding help file...", "\n"))

      utils::download.file(ip$help_url, temphelp, mode = "wb")
      while(!fs::file_exists(temphelp)) {
        tryCatch(utils::download.file(ip$help_url, temphelp, mode = "wb"), error = function(e) {
          cat(crayon::white(crayon::bgRed("Error, retrying download...\n")))
          message(e)
          fs::file_delete(fs::dir_ls(temp))
        })
      }

      utils::unzip(temphelp, exdir = fs::path(ipeds_path, "helpfiles"))

      fs::dir_delete(temp)

    })
}



scrape_ipeds_datacenter_files <- function() {

  cli::cli_alert_info("Updating local list of IPEDS Datacenter files...")

  pb <- progress::progress_bar$new(total = 100, show_after = 0)
  pb$tick(0)

  url1 <- "https://nces.ed.gov/ipeds/datacenter/login.aspx?gotoReportId=8"
  url2 <- "https://nces.ed.gov/ipeds/datacenter/DataFiles.aspx"

  UA <- "Mozilla/5.0 (Windows NT 6.1; rv:75.0) Gecko/20100101 Firefox/75.0"

  html <- httr::GET(url1, httr::user_agent(UA))
  pb$update(2/10)
  html <- httr::GET(url2, httr::user_agent(UA))
  pb$update(4/10)
  page <- html %>% xml2::read_html()
  pb$update(6/10)


  form <- list(
    `__VIEWSTATE` = page %>%
      rvest::html_node(xpath = "//input[@name='__VIEWSTATE']") %>%
      rvest::html_attr("value"),
    `__VIEWSTATEGENERATOR` = page %>%
      rvest::html_node(xpath = "//input[@name='__VIEWSTATEGENERATOR']") %>%
      rvest::html_attr("value"),
    `__EVENTVALIDATION` = page %>%
      rvest::html_node(xpath = "//input[@name='__EVENTVALIDATION']") %>%
      rvest::html_attr("value"),
    `ctl00$contentPlaceHolder$ddlYears` = "-1",
    `ddlSurveys` = "-1",
    `ctl00$contentPlaceHolder$ibtnContinue.x` = sample(50, 1),
    `ctl00$contentPlaceHolder$ibtnContinue.y` = sample(20, 1)
  )

  Headers <- httr::add_headers(
    `Accept-Encoding` = "gzip, deflate, br",
    `Accept-Language` = "en-GB,en;q=0.5",
    `Connection` = "keep-alive",
    `Host` = "nces.ed.gov",
    `Origin` = "https://nces.ed.gov",
    `Referer` = url2,
    `Upgrade-Insecure-Requests` = "1"
  )

  Cookies <- httr::set_cookies(stats::setNames(
    c(httr::cookies(html)$value, "true"),
    c(httr::cookies(html)$name, "fromIpeds")
  ))

  Result <- httr::POST(url2, body = form, httr::user_agent(UA), Headers, Cookies)

  pb$update(8/10)

  ipeds_scrape_raw <- Result %>%
    xml2::read_html() %>%
    rvest::html_node("#contentPlaceHolder_tblResult") %>%
    rvest::html_table() %>%
    dplyr::as_tibble()

  ipeds <- ipeds_scrape_raw %>%
    janitor::clean_names() %>%
    dplyr::mutate(
      title = stringr::str_remove_all(title, "[^[:ascii:]]"),
      title = stringi::stri_encode(title, "", "ASCII")
    ) %>%
    dplyr::mutate(
      title = stringr::str_replace_all(title, "\\n", " "),
      title = stringr::str_remove_all(title, "\\r")
    ) %>%
    dplyr::mutate(rv_title = stringr::str_detect(title, "revised")) %>%
    dplyr::mutate(revision_date = stringr::str_extract(title, "\\(revised .*\\)$"))
    dplyr::mutate(title = stringr::str_remove(title, "\\s?\\(?revised.*\\)?$")) %>%
    dplyr::mutate(title = stringr::str_squish(title)) %>%
    dplyr::filter(!stringr::str_detect(data_file, "FLAGS")) %>%
    dplyr::mutate(
      data_url = paste0("https://nces.ed.gov/ipeds/datacenter/data/", data_file, ".zip"),
      help_url = paste0("https://nces.ed.gov/ipeds/datacenter/data/", data_file, "_Dict.zip")
    ) %>%
    dplyr::select(-programs, -dictionary, -stata_data_file)

  pb$update(1)

  cli::cli_alert_success("Update complete.")

  return(ipeds)
}

#' Update local list of available data center files
#' @description
#' \lifecycle{experimental}
#' This function is primarily internal. It is used to update (or download if it does not exist) a local index of the data files available from IPEDS data center (but not the data itself).  If the local index is less than 1 month old, it does not update as scraping the data center is time consuming and new files are added only a few times a year.  This behavior can be circumvented by using \code{`force = TRUE`}.  If the local index is over 1 month old, it is updated automatically.
#' @param force Logical indicating whether to force an update if local copy is less than 1 month old. Defaults to FALSE
#' @examples
#' \dontrun{
#' update_available_ipeds(force = TRUE)
#' }
#' @export
update_available_ipeds <- function(force = FALSE) {

  pkg_path <- system.file(package = "tidyipeds")

  if (!fs::dir_exists(fs::path(pkg_path, "ipeds_data"))) fs::dir_create(fs::path(pkg_path, "ipeds_data"))

  ipeds_path <- fs::path(pkg_path, "ipeds_data")

  if (fs::file_exists(fs::path(ipeds_path, "datacenter_scrape.rds")) & !force) {

    existing_date <- fs::file_info(fs::path(ipeds_path, "datacenter_scrape.rds"))$modification_time
    if (difftime(lubridate::now(), existing_date, units = "weeks") > 4) {

      cli::cli_alert_warning("The locally stored list of available IPEDS data files is over 1 month old.")

      old_ipeds <- readr::read_rds(fs::path(ipeds_path, "datacenter_scrape.rds"))

      ipeds <- scrape_ipeds_datacenter_files()

      readr::write_rds(ipeds, fs::path(ipeds_path, "datacenter_scrape.rds"))

      cli::cli_alert_success("Update completed.")

      compare_ipeds_scrape(old_ipeds, ipeds)

    } else {

      cli::cli_alert_info("Using locally stored list of available IPEDS data files as it was updated within the last month. To force an update, run  `update_available_ipeds(force = TRUE`)")

    }
  } else {

    ipeds <- scrape_ipeds_datacenter_files()

    if(force & fs::file_exists(fs::path(ipeds_path, "datacenter_scrape.rds"))) {
      old_ipeds <- readr::read_rds(fs::path(ipeds_path, "datacenter_scrape.rds"))
      compare_ipeds_scrape(old_ipeds, ipeds)
    }

    readr::write_rds(ipeds, fs::path(ipeds_path, "datacenter_scrape.rds"))

  }

}


compare_ipeds_scrape <- function(old, new) {

  ipeds_diff <- anti_join(new, old, by = c("year", "survey", "title", "data_file", "rv_title", "revision_date"))

  if(nrow(ipeds_diff) == 0) return(cli::cli_alert_info("The locally stored list of available IPEDS data files matches the online data center. No new surveys or survey revisions have been added.", wrap = T))

  if (nrow(ipeds_diff %>% dplyr::filter(!rv_title)) > 0) {
    cli::cli_alert_info(cli::rule(left = "New surveys have been added to the data center", line_col = "green"))
    ipeds_diff %>%
      dplyr::filter(!rv_title) %>%
      select(year, survey, title, data_file) %>%
      print()
    cli::cat_line()
  }

  if (nrow(ipeds_diff %>% dplyr::filter(rv_title)) > 0) {
    cli::cli_alert_info(cli::rule(left = "The following surveys have been updated to include revised files", line_col = "green"))
    ipeds_diff %>%
      dplyr::filter(rv_title) %>%
      select(year, survey, title, data_file, revision_date) %>%
      print()
    cli::cat_line()
  }


  #TODO: Add ability to bring this info up again later in the session?

}


#TODO: If comparison yields new data, add an option to update all, update any currently downloaded surveys that match the update, or none.
# If they don't do it now, there should be an update function that will do it at any point in the future (or only in session?)  We need to keep track of when the data and the index or not in sync with respect to provisional/rv data files.  Perhaps a flag somewhere that indicates this for files and then can be checked against the datascenter_scrape.rds.







