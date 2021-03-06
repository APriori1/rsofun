#' Run SOFUN and read output
#'
#' Runs the model and reads output in once.
#'
#' @param settings A named list containing the simulation settings (see vignette_rsofun.pdf for more information and examples).
#' @param setup A named list containing the model setup settings (see vignette_rsofun.pdf for more information and examples).
#'
#' @return Returns a named list of data frames (tibbles) containing model outputs (separate data frames for 
#' each site, with columns for the different model output variables). Note that outputs generated by the
#' \code{"lonlat"} model setup are not read into R and not returned by \code{runread_sofun()} due to excessive
#' memory requirements. 
#' @export
#'
#' @examples mod <- runread_sofun( settings = settings_sims, setup = setup_sofun )
#' 
runread_sofun <- function( settings, setup ){

  ## run simulations
  out_std <- run_sofun( settings, setup )

  ## don't save standard output to save space
  rm("out_std")

  ## read output into one big list
  ddf_list <- read_sofun( settings, setup )

  return(ddf_list)
}
  

##-----------------------------------------------------------
## Runs the model.
##-----------------------------------------------------------
run_sofun <- function( settings, setup ){
  
  ## change to directory from where model is executed
  here <- getwd() # save current working directory
  setwd( settings$dir_sofun )

  ## How to run the model from the command line (shell) is different for each implementation (Python and Fortran)
  if (settings$implementation=="fortran"){

    ## Compile source code
    if (setup$do_compile){

      cmd <- paste0("make ", setup$model)
      system( cmd )

    } else if (!file.exists(paste0("run", setup$model))){

      print("Copying executable, compiled on a Mac with gfortran into SOFUN run directory...")
      system( paste0( "cp ", path.package("rsofun"), "/extdata/run", setup$model, " ." ) )

      # ## Download executable from CX1
      # rlang::warn( paste0("Executable run", setup$model, " is not available locally. Download it from CX1..."))
      # download_from_remote(   path_remote = paste0("/work/bstocker/labprentice/data/sofun_executables/run/", setup$model ),
      #                         path_local = settings$dir_sofun 
      #                         )

      if (!file.exists(paste0("run", setup$model))) abort( paste( "Executable could not be downloaded: ", paste0("run", setup$model)) )

    }

    if (settings$ensemble){
      ## Run all simulations in this ensemble as individual simulations. Runnames are given by the sitenames in the ensemble
      out_std <- purrr::map( as.list(settings$sitenames), ~run_sofun_bysite( ., setup ) )      
    } else {
      ## Run single simulation. Runname is given by `settings$name`.
      run_sofun_bysite( settings$name, setup )
    }

  }

  setwd( here )
  return(out_std)
}


##-----------------------------------------------------------
## Reads output.
##-----------------------------------------------------------
read_sofun <- function( settings, setup ){
  
  ## processing output files requires CDO
  cdopath <- system("which cdo", ignore.stderr=TRUE)

  ## First, process NetCDF which are written separately for each simulation year
  print("processing NetCDF outputs...")
  tmpdir <- paste0( path.package("rsofun"), "/tmp" )
  if (!dir.exists(tmpdir)) system( paste0( "mkdir ", tmpdir ) )
  tmp <- purrr::map( as.list(settings$sitenames), ~proc_ncout_sofun_bysite( ., settings$path_output_nc ) )
  rm("tmp")

  ## Open and read daily output from NetCDF file for each site
  ddf_list <- list()

  if (settings$setup=="lonlat"){
    ## annual output (daily output is not read into R)
    print("reading from annual NetCDF files...")
    ddf_list$annual <- purrr::map( as.list(settings$sitenames), ~read_ncout_sofun_annual( ., settings ) )
    names(ddf_list$annual) <- settings$sitenames
    rlang::warn("read_sofun(): Daily output is not read into R.")
  
  } else {
    ## daily output
    print("reading from daily NetCDF files...")
    ddf_list$daily <- purrr::map( as.list(settings$sitenames), ~read_ncout_sofun_daily( ., settings ) )
    names(ddf_list$daily) <- settings$sitenames
  
    ## remove sites from list if they are missing (appear as NA in list)
    ddf_list$daily <- na.omit.list( ddf_list$daily )

  }

  return(ddf_list)
}


##-----------------------------------------------------------
## Runs the model for one site.
##-----------------------------------------------------------
run_sofun_bysite <- function( sitename, setup ){

  cmd <- paste0( "echo ", sitename, " | ./run", setup$model )
  out_std <- system( cmd, intern = TRUE )
  
  return(out_std)
}


##-----------------------------------------------------------
## Processes output, combining annual files into multi-annual
## Using CDO commands. See file 'source proc_output.sh
##-----------------------------------------------------------
proc_ncout_sofun_bysite <- function( sitename, path_nc ){
  print(paste0("processing ", sitename, "..."))
  filelist <- system( paste0( "ls ", path_nc, "/", sitename, ".????.*.nc" ), intern = TRUE )
  if (length(filelist)>0){
    system( paste0( 
      path.package("rsofun"), "/bash/proc_output_sofun.sh ", sitename, " ", path_nc, 
      " >",  path.package("rsofun"), "/tmp/ncproc_", sitename, ".out", 
      " 2>", path.package("rsofun"), "/tmp/ncproc_", sitename, ".err" 
      ) )
  } else {
    rlang::warn("Assuming that annual files have already been combined to multi-annual.")
  }
}

##-----------------------------------------------------------
## Gets daily SOFUN model output for multiple variables
##-----------------------------------------------------------
read_ncout_sofun_daily <- function( expname, settings ){

  print(paste("Reading NetCDF for", expname ) )

  ## define vector of output variable names
  vars <- c()
  if ( settings$loutdgpp) vars <- c( vars, "gpp" )
  if ( settings$loutdrd) vars <- c( vars, "rd" )
  if ( settings$loutdtransp) vars <- c( vars, "transp" )
  if ( settings$loutdalpha) vars <- c( vars, "alpha" )
  if ( settings$loutdaet) vars <- c( vars, "aet" )
  if ( settings$loutdpet) vars <- c( vars, "pet" )
  if ( settings$loutdwcont) vars <- c( vars, "wcont" )
  if ( settings$loutdtemp) vars <- c( vars, "temp" )
  if ( settings$loutdfapar) vars <- c( vars, "fapar" )
  if ( settings$loutdtemp_soil) vars <- c( vars, "temp_soil" )
  
  ## read one file to initialise data frame and get years
  filnam_mod <- paste0( expname, ".d.", vars[1], ".nc" )
  path       <- paste0( settings$path_output_nc, filnam_mod )
  
  if (file.exists(path)){

    nc         <- ncdf4::nc_open( path )
    gpp        <- ncdf4::ncvar_get( nc, varid = vars[1] )
    time       <- ncdf4::ncvar_get( nc, varid = "time" )
    ncdf4::nc_close(nc)

    ## convert to a ymd datetime object
    time <- conv_noleap_to_ymd( time, since="2001-01-01" )

    ddf <- tibble( date=time )

    readvars <- vars

    if (class(nc)!="try-error") { 

      for (ivar in readvars){
        filnam_mod <- paste0( expname, ".d.", ivar, ".nc" )
        path       <- paste0( settings$path_output_nc, filnam_mod )
        nc         <- ncdf4::nc_open( path )
        addvar     <- ncdf4::ncvar_get( nc, varid = ivar )
        ddf <- tibble( date=time, ivar=addvar ) %>% 
               setNames( c("date", ivar) ) %>% 
               right_join( ddf, by = "date" )
      }

    }

  } else {

    ddf <- NA

  }

  return( ddf )
}


##-----------------------------------------------------------
## Gets annual SOFUN model output for multiple variables
##-----------------------------------------------------------
read_ncout_sofun_annual <- function( expname, settings ){

  print(paste("Reading NetCDF for", expname ) )

  ## define vector of output variable names
  vars <- c()
  if ( settings$loutwaterbal) vars <- c( vars, "alpha", "aet", "pet" )
  if ( settings$loutgpp) vars <- c( vars, "gpp" )
  
  ## read one file to initialise data frame and get years
  filnam_mod <- paste0( expname, ".a.", vars[1], ".nc" )
  path       <- paste0( settings$path_output_nc, filnam_mod )
  
  if (file.exists(path)){

    adf  <- list()
    nc         <- ncdf4::nc_open( path )
    adf[["time"]] <- ncdf4::ncvar_get( nc, varid = "time" ) %>% conv_noleap_to_ymd( since="2001-01-01" )
    ncdf4::nc_close(nc)
    
    readvars <- vars

    if (class(nc)!="try-error") { 

      for (ivar in readvars){
        filnam_mod    <- paste0( expname, ".a.", ivar, ".nc" )
        path          <- paste0( settings$path_output_nc, filnam_mod )
        nc            <- ncdf4::nc_open( path )
        adf[[ ivar ]] <- ncdf4::ncvar_get( nc, varid = ivar )
        ncdf4::nc_close(nc)
      }

    }

  } else {

    adf <- NA

  }

  return( adf )
}

## copied from https://gist.github.com/rhochreiter/7029236
na.omit.list <- function(y) { return(y[!sapply(y, function(x) all(is.na(x)))]) }

