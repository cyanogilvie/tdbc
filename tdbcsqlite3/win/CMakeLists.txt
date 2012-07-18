# Tcl Extension Build File

project (tdbc-sqlite3 C)

set( PACKAGE_NAME ${PROJECT_NAME} )
set( PACKAGE_VER_MAJOR 1 )
set( PACKAGE_VER_MINOR 0b17 )
set( PACKAGE_VER_PATCH 0 )


# ----- Policies ---------------------------------------------------------------

  cmake_minimum_required (VERSION 2.8) # Use 2.8 or higher so we don't need to CLEAN_DIRECT_OUTPUT
  cmake_policy( SET CMP0005 NEW )      # Automatically escape preprocessor defines


# ----- Sources --------------------------------------------------------------

  set( SRCROOT .. )

  set( pkg_runtime_scripts
    ${SRCROOT}/library/tdbcsqlite3.tcl
  )

  set( license_txt ${SRCROOT}/license.terms )

  source_group( "EXT ${PROJECT_NAME} Files" FILES 
    ${pkg_runtime_scripts} 
    ${license_txt}
  )


# ----- General build rules ----------------------------------------------------
  # You shouldn't need to change these

  set( PACKAGE_VERSION ${PACKAGE_VER_MAJOR}.${PACKAGE_VER_MINOR}.${PACKAGE_VER_PATCH} )

  set( install_targets )  # List of targets to be installed


# ----- Extension-specific build rules -----------------------------------------

  # No pkgIndex is required - we install .tcl sources as tcl modules (.tm)
  
  # Pure-Tcl extension - nothing to build
  

# ----- Install rules ----------------------------------------------------------

  # Install modules 
  install_tm( ${SRCROOT}/library/tdbcsqlite3.tcl ${PACKAGE_NAME} ${PACKAGE_VERSION} )
  
  # Install license and public headers
  install( FILES ${license_txt} DESTINATION ${TCL_INSTALL_PREFIX_INCLUDE}/LICENSE
    RENAME ${PROJECT_NAME}.txt )
