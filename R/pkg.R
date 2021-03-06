# Package dependency:
# list(
#   name = 'ggplot2',
#   source = 'CRAN',
#   version = '0.9.3.1', # or: '>= 3.0', 'github:hadley/ggplot2/fix/axis', ''
# )

# Package record:
# list(
#   name = 'ggplot2',
#   source = 'github',
#   version = '0.9.3.1',
#   gh_repo = 'ggplot2',
#   gh_username = 'hadley',
#   gh_ref = 'master',
#   gh_sha1 = '66b81e9307793029f6083fc6108592786a564b09'
# # Optional:
#   , gh_subdir = 'pkg'
# )

# Checks whether a package was installed from source and is
# within the packrat ecosystem
hasSourcePathInDescription <- function(pkgNames, lib.loc) {

  pkgNames[unlist(lapply(pkgNames, function(pkg) {

    # Get the package location in the library path
    loc <- find.package(pkg, lib.loc, quiet = TRUE)

    # If there was no package, FALSE
    if (!length(loc)) return(FALSE)

    # If there's no DESCRIPTION (not sure how this could happen), warn + FALSE
    if (!file.exists(file.path(loc, "DESCRIPTION"))) {
      warning("Package '", pkg, "' was found at library location '", loc, "' but has no DESCRIPTION")
      return(FALSE)
    }

    # Read the DESCRIPTION and look for Packrat fields
    dcf <- readDcf(file.path(loc, "DESCRIPTION"))
    "InstallSourcePath" %in% colnames(dcf)

  }))]

}

# Returns package records for a package that was installed from source by
# packrat (and is within the packrat ecosystem)
getPackageRecordsInstalledFromSource <- function(pkgs, lib.loc) {
  lapply(pkgs, function(pkg) {
    loc <- find.package(pkg, lib.loc)
    dcf <- as.data.frame(readDcf(file.path(loc, "DESCRIPTION")), stringsAsFactors = FALSE)
    deps <- combineDcfFields(dcf, c("Depends", "Imports", "LinkingTo"))
    deps <- deps[deps != "R"]
    db <- NULL
    record <- structure(list(
      name = pkg,
      source = 'source',
      version = dcf$Version,
      source_path = dcf$InstallSourcePath
    ), class=c('packageRecord', 'source'))
  })
}

# Get package records for those manually specified with source.packages
getPackageRecordsManuallySpecified <- function(pkgNames,
                                               source.packages) {

  # Only look at packages within source.packages
  pkgNames <- pkgNames[pkgNames %in% rownames(source.packages)]

  lapply(pkgNames, function(pkgName) {
    source_path <- as.character(source.packages[pkgName,"path"])
    version <- as.character(source.packages[pkgName,"version"])

    ## If it ends with tar.gz, pull the DESCRIPTION file out
    if (endswith(source_path, "tar.gz")) {
      tempdir <- file.path(tempdir(), paste("packrat", pkgName, version, sep = "-"))
      dir.create(tempdir, recursive = TRUE)
      untar(source_path, exdir = tempdir)
      sourceDesc <- as.data.frame(
        readDcf(file.path(tempdir, pkgName, "DESCRIPTION"))
      )
    } else {
      # Read the dependency information directly from the DESCRIPTION file
      sourceDesc <- as.data.frame(
        readDcf(file.path(source.packages[pkgName,"path"], "DESCRIPTION")))
    }
    deps <- combineDcfFields(sourceDesc, c("Depends", "Imports", "LinkingTo"))
    deps <- deps[deps != "R"]
    db <- NULL
    record <- structure(list(
      name = pkgName,
      source = 'source',
      version = version,
      source_path = source_path
    ), class=c('packageRecord', 'source'))
  })

}

getPackageRecordsExternalSource <- function(pkgNames,
                                            available,
                                            lib.loc,
                                            missing.package) {

  lapply(pkgNames, function(pkgName) {
    # This package is from an external source (CRAN-like repo or github);
    # attempt to get its description from the installed package database.
    pkgDescFile <- system.file('DESCRIPTION',
                               package=pkgName,
                               lib.loc = lib.loc)
    if (nchar(pkgDescFile) == 0) {
      if (pkgName %in% rownames(available)) {
        pkg <- available[pkgName,]
        df <- data.frame(
          Package = pkg[["Package"]],
          Version = pkg[["Version"]],
          Repository = "CRAN")
      } else {
        return(missing.package(pkgName, lib.loc))
      }
    } else {
      df <- as.data.frame(readDcf(pkgDescFile))
    }
    inferPackageRecord(df)
  })

}

# Returns a package records for the given packages
getPackageRecords <- function(pkgNames,
                              available=NULL,
                              source.packages=NULL,
                              recursive=TRUE,
                              lib.loc=NULL,
                              missing.package = function(package, lib.loc) {
                                stop('The package "', package, '" is not installed in ', ifelse(is.null(lib.loc), 'the current libpath', lib.loc))
                              }) {

  # First, get the package records for packages installed from source
  pkgsInstalledFromSource <- hasSourcePathInDescription(pkgNames, lib.loc = lib.loc)
  srcPkgRecords <- getPackageRecordsInstalledFromSource(pkgsInstalledFromSource,
                                                        lib.loc = lib.loc)

  pkgNames <- setdiff(pkgNames, pkgsInstalledFromSource)

  # Next, get the packge records for packages manually specified in source.packages
  manualSrcPkgRecords <- getPackageRecordsManuallySpecified(
    pkgNames,
    source.packages
  )

  pkgNames <- setdiff(pkgNames, sapply(manualSrcPkgRecords, "[[", "name"))

  # Finally, get the package records for packages that are now presumedly from
  # an external source
  externalPkgRecords <- getPackageRecordsExternalSource(pkgNames,
                                                        available = available,
                                                        lib.loc = lib.loc,
                                                        missing.package = missing.package)

  pkgNames <- setdiff(pkgNames, sapply(externalPkgRecords, "[[", "name"))

  # Collect the records together
  allRecords <- c(
    srcPkgRecords,
    manualSrcPkgRecords,
    externalPkgRecords
  )

  # Remove any null records
  allRecords <- dropNull(allRecords)

  # Now get recursive package dependencies if necessary
  if (recursive) {
    allRecords <- lapply(allRecords, function(record) {
      deps <- tools::package_dependencies(
        record$name,
        available,
        c("Depends", "Imports", "LinkingTo"),
        recursive = FALSE
      )[[record$name]]
      record$depends <- getPackageRecords(
        deps,
        available,
        source.packages,
        TRUE,
        lib.loc = lib.loc,
        missing.package = missing.package)
      record
    })
  }

  allRecords
}

# Reads a description file and attempts to infer where the package came from.
# Currently works only for packages installed from CRAN or from GitHub using
# devtools 1.4 or later.
inferPackageRecord <- function(df) {
  name <- as.character(df$Package)
  ver <- as.character(df$Version)

  if (!is.null(df$Repository) &&
        identical(as.character(df$Repository), 'CRAN')) {
    # It's CRAN!
    return(structure(list(
      name = name,
      source = 'CRAN',
      version = ver
    ), class=c('packageRecord', 'CRAN')))
  } else if (!is.null(df$GithubRepo)) {
    # It's GitHub!
    return(structure(c(list(
      name = name,
      source = 'github',
      version = ver,
      gh_repo = as.character(df$GithubRepo),
      gh_username = as.character(df$GithubUsername),
      gh_ref = as.character(df$GithubRef),
      gh_sha1 = as.character(df$GithubSHA1)),
      c(gh_subdir = as.character(df$GithubSubdir))
    ), class=c('packageRecord', 'github')))
  } else if (identical(as.character(df$Priority), 'base')) {
    # It's a base package!
    return(NULL)
  } else if (!is.null(df$biocViews)) {
    # It's Bioconductor!
    return(structure(list(
      name = name,
      source = 'Bioconductor',
      version = ver
    ), class=c('packageRecord', 'Bioconductor')))
  } else if (identical(as.character(df$InstallSource), "source")) {
    # It's a local source package!
    return(structure(list(
      name = name,
      source = 'source',
      version = ver
    ), class=c('packageRecord', 'source')))
  } else if ((identical(name, "manipulate") || identical(name, "rstudio")) &&
               identical(as.character(df$Author), "RStudio")) {
    # The 'manipulate' and 'rstudio' packages are auto-installed by RStudio
    # into the package library; ignore them so they won't appear orphaned.
    return(NULL)
  } else {
    warning("Couldn't figure out the origin of package ", name)
    return(structure(list(
      name = name,
      source = 'unknown',
      version = ver
    ), class='packageRecord'))
  }
}

# Given a list of source package paths, parses the DESCRIPTION for each and
# returns a data frame containing each (with row names given by package names)
getSourcePackageInfo <- function(source.packages) {
  info <- lapply(source.packages, getSourcePackageInfoImpl)
  result <- do.call(rbind, info)
  row.names(result) <- result$name
  result
}

getSourcePackageInfoImpl <- function(path) {

  ## For tarballs, we unzip them to a temporary directory and then read from there
  tempdir <- file.path(tempdir(), "packrat", path)
  if (endswith(path, "tar.gz")) {
    paths <- untar(path, exdir = tempdir)
    folderName <- list.files(tempdir, full.names = TRUE)[[1]]
  } else {
    folderName <- path
  }
  descPath <- file.path(folderName, "DESCRIPTION")
  if (!file.exists(descPath)) {
    stop("Cannot treat ", path, " as a source package directory; ", descPath,
         " is missing.")
  }
  desc <- as.data.frame(readDcf(descPath))
  data.frame(
    name = as.character(desc$Package),
    version = as.character(desc$Version),
    path = normalizePath(path, winslash='/'),
    stringsAsFactors = FALSE
  )

}

pick <- function(property, package, defaultValue = NA) {
  func <- function(packageRecord) {
    if (is.null(packageRecord))
      return(defaultValue)
    else
      return(packageRecord[[property]])
  }
  if (!missing(package)) {
    return(func(package))
  } else {
    return(func)
  }
}

# If called without a second argument, returns a curried function. If called
# with a second argument then it returns the package without the indicated
# properties.
strip <- function(properties, package) {
  func <- function(packageRecord) {
    packageRecord[!names(packageRecord) %in% properties]
  }
  if (!missing(package)) {
    return(func(package))
  } else {
    return(func)
  }
}

# Returns a character vector of package names. Depends are ignored.
pkgNames <- function(packageRecords) {
  if (length(packageRecords) == 0)
    return(character(0))
  sapply(packageRecords, pick("name"))
}

# Filters out all record properties except name and version. Dependencies are
# dropped.
pkgNamesAndVersions <- function(packageRecords) {
  if (length(packageRecords) == 0)
    return(character(0))
  lapply(packageRecords, function(pkg) {
    pkg[names(pkg) %in% c('name', 'version')]
  })
}

# Recursively filters out all record properties except name, version, and
# depends.
pkgNamesVersDeps <- function(packageRecords) {
  if (length(packageRecords) == 0)
    return(character(0))
  lapply(packageRecords, function(pkg) {
    pkg <- pkg[names(pkg) %in% c('name', 'version', 'depends')]
    pkg$depends <- pkgNamesVersDeps(pkg$depends)
    return(pkg)
  })
}

# Searches package records recursively looking for packages
searchPackages <- function(packages, packageNames) {
  lapply(packageNames, function(pkgName) {
    for (pkg in packages) {
      if (pkg$name == pkgName)
        return(pkg)
      if (!is.null(pkg$depends)) {
        found <- searchPackages(pkg$depends, pkgName)[[1]]
        if (!is.null(found))
          return(found)
      }
    }
    return(NULL)
  })
}

# Returns a linear list of package records, sorted by name, with all dependency
# information removed (or, optionally, reduced to names)
flattenPackageRecords <- function(packageRecords, depInfo = FALSE, sourcePath = FALSE) {
  visited <- new.env(parent=emptyenv())
  visit <- function(pkgRecs) {
    for (rec in pkgRecs) {
      if (isTRUE(depInfo)) {
        rec$requires <- pkgNames(rec$depends)
        if (length(rec$requires) == 0)
          rec$requires <- NA_character_
        else if (length(rec$requires) > 1)
          rec$requires <- paste(rec$requires, collapse = ', ')
      }
      visit(rec$depends)
      rec$depends <- NULL
      if (!isTRUE(sourcePath))
        rec$source_path <- NULL
      visited[[rec$name]] <- rec
    }
  }
  visit(packageRecords)
  lapply(sort(ls(visited)), function(name) {
    visited[[name]]
  })
}

# States: NA (unchanged), remove, add, upgrade, downgrade, crossgrade
# (crossgrade means name and version was the same but something else was
# different, i.e. different source or GitHub SHA1 hash or something)

diff <- function(packageRecordsA, packageRecordsB) {
  removed <- pkgNameDiff(packageRecordsA, packageRecordsB)
  removed <- structure(rep.int('remove', length(removed)),
                       names = removed)

  added <- pkgNameDiff(packageRecordsB, packageRecordsA)
  added <- structure(rep.int('add', length(added)),
                     names = added)

  both <- pkgNameIntersect(packageRecordsA, packageRecordsB)
  both <- structure(
    sapply(both, function(pkgName) {
      pkgA <- searchPackages(packageRecordsA, pkgName)[[1]]
      pkgB <- searchPackages(packageRecordsB, pkgName)[[1]]

      if (identical(strip(c('depends', 'source_path'), pkgA),
                    strip(c('depends', 'source_path'), pkgB)))
        return(NA)
      verComp <- compareVersion(pkgA$version, pkgB$version)
      if (verComp < 0)
        return('upgrade')
      else if (verComp > 0)
        return('downgrade')
      else
        return('crossgrade')
    }),
    names = both
  )

  return(c(removed, added, both))
}

pkgNameIntersect <- function(packageRecordsA, packageRecordsB) {
  a <- pkgNames(flattenPackageRecords(packageRecordsA))
  b <- pkgNames(flattenPackageRecords(packageRecordsB))
  intersect(a, b)
}

pkgNameDiff <- function(packageRecordsA, packageRecordsB) {
  a <- pkgNames(flattenPackageRecords(packageRecordsA))
  b <- pkgNames(flattenPackageRecords(packageRecordsB))
  setdiff(a, b)
}
