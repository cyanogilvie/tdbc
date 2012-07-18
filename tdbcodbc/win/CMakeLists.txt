# Tcl Extension Build File

project (tdbcodbc C)

set( PACKAGE_NAME ${PROJECT_NAME} )
set( PACKAGE_VER_MAJOR 1 )
set( PACKAGE_VER_MINOR 0b17 )
set( PACKAGE_VER_PATCH 0 )


# ----- Policies ---------------------------------------------------------------

  cmake_minimum_required (VERSION 2.8) # Use 2.8 or higher so we don't need to CLEAN_DIRECT_OUTPUT
  cmake_policy( SET CMP0005 NEW )      # Automatically escape preprocessor defines


# ----- Sources --------------------------------------------------------------

  set( SRCROOT .. )

  include_directories ( ${TCL_INCLUDE_PATH} ${TCL_TDBC_INCLUDE_PATH} ${SRCROOT}/generic )

  set( generic_src
    ${SRCROOT}/generic/tdbcodbc.c
    ${SRCROOT}/generic/odbcStubInit.c
  )
  
  set( pkg_runtime_scripts
    ${SRCROOT}/library/pkgIndex.tcl
    ${SRCROOT}/library/tdbcodbc.tcl
  )

  set( license_txt ${SRCROOT}/license.terms )

  source_group( "EXT ${PROJECT_NAME} Files" FILES 
    ${generic_src} 
    ${pkg_runtime_scripts} 
    ${license_txt}
  )


# ----- General build rules ----------------------------------------------------
  # You shouldn't need to change these

  set( PACKAGE_VERSION ${PACKAGE_VER_MAJOR}.${PACKAGE_VER_MINOR}.${PACKAGE_VER_PATCH} )
  set( _PKG_LIB_FILE_CORE ${PROJECT_NAME}${PACKAGE_VER_MAJOR}${PACKAGE_VER_MINOR} )
  set( PKG_LIB_FILE ${CMAKE_SHARED_LIBRARY_PREFIX}${_PKG_LIB_FILE_CORE}${CMAKE_SHARED_LIBRARY_SUFFIX} )
  message(STATUS "Building ${PROJECT_NAME} ${PACKAGE_VERSION} as '${PKG_LIB_FILE}'")

  set( install_targets )  # List of targets to be installed


# ----- Extension-specific build rules -----------------------------------------

  # Generate the pkgIndex file
  set( TCL_VERSION_REQ 8.5 )

  configure_file( ${SRCROOT}/pkgIndex.tcl.in ${CMAKE_CURRENT_SOURCE_DIR}/${SRCROOT}/library/pkgIndex.tcl @ONLY )

  # Build the project library
  add_library( ${PROJECT_NAME} ${generic_src} )
  target_link_libraries( ${PROJECT_NAME} ${TCL_LINK_TARGETS} ${TCL_TDBC_LINK_TARGETS} )
  set_property( TARGET ${PROJECT_NAME} PROPERTY OUTPUT_NAME ${_PKG_LIB_FILE_CORE} )
  set_property( TARGET ${PROJECT_NAME} APPEND PROPERTY COMPILE_DEFINITIONS
    ${TCLEXT_STD_DEFINES}
    PACKAGE_NAME="${PROJECT_NAME}"
    PACKAGE_VERSION="${PACKAGE_VERSION}"
    BUILD_${PROJECT_NAME}
    USE_THREAD_STORAGE=1
    USE_TCLOO_STUBS
  )
  set( install_targets ${install_targets} ${PROJECT_NAME} )


# ----- Install rules ----------------------------------------------------------

  # Install package scripts under TCL_LIBRARY_PATH
  set( pkg_path_runtime ${TCL_INSTALL_PREFIX_PACKAGE}/${PROJECT_NAME}${PACKAGE_VER_MAJOR}.${PACKAGE_VER_MINOR} )
  install( FILES ${pkg_runtime_scripts} DESTINATION ${pkg_path_runtime} )

  # Install binaries alongside Tcl binaries
  install( TARGETS ${install_targets} 
    RUNTIME DESTINATION ${TCL_INSTALL_PREFIX_BIN}
    ARCHIVE DESTINATION ${TCL_INSTALL_PREFIX_ARC}
  )
  
  # Install license and public headers
  install( FILES ${license_txt} DESTINATION ${TCL_INSTALL_PREFIX_INCLUDE}/LICENSE
    RENAME ${PROJECT_NAME}.txt )
